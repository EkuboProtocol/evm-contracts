// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {IAuctions} from "./interfaces/IAuctions.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {PoolKey} from "./types/poolKey.sol";
import {AuctionKey} from "./types/auctionKey.sol";
import {AuctionConfig} from "./types/auctionConfig.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {SaleRateOverflow, computeSaleRate} from "./math/twamm.sol";
import {computeFee} from "./math/fee.sol";
import {nextValidTime, MAX_ABS_VALUE_SALE_RATE_DELTA} from "./math/time.sol";
import {NATIVE_TOKEN_ADDRESS, MAX_TICK_SPACING} from "./math/constants.sol";
import {BoostedFeesLib} from "./libraries/BoostedFeesLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @author Moody Salem <moody@ekubo.org>
/// @title Auctions
/// @notice TWAMM-based token auction manager.
contract Auctions is IAuctions, UsesCore, BaseLocker, BaseNonfungibleToken, PayableMulticallable {
    using CoreLib for *;
    using BoostedFeesLib for *;
    using TWAMMLib for *;
    using FlashAccountantLib for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;
    /// @notice The BoostedFees extension address
    address public immutable BOOSTED_FEES;

    uint256 private constant CALL_TYPE_SELL_BY_AUCTION = 0;
    uint256 private constant CALL_TYPE_COMPLETE_AUCTION = 1;
    uint256 private constant CALL_TYPE_COLLECT_CREATOR_PROCEEDS = 2;
    uint256 private constant CALL_TYPE_START_BOOST = 3;

    constructor(address owner, ICore core, ITWAMM twamm, address boostedFees)
        UsesCore(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
    }

    /// @inheritdoc IAuctions
    function sellByAuction(uint256 tokenId, AuctionKey memory auctionKey, uint112 saleRate)
        public
        payable
        authorizedForNft(tokenId)
    {
        uint32 graduationPoolTickSpacing = auctionKey.config.graduationPoolTickSpacing();
        if (graduationPoolTickSpacing == 0 || graduationPoolTickSpacing > MAX_TICK_SPACING) {
            revert InvalidGraduationPoolTickSpacing();
        }

        if (saleRate == 0) {
            revert ZeroSaleRateDelta();
        }

        if (saleRate > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            revert SaleRateOverflow();
        }

        if (auctionKey.config.startTime() < block.timestamp) {
            revert AuctionAlreadyStarted();
        }

        lock(abi.encode(CALL_TYPE_SELL_BY_AUCTION, msg.sender, tokenId, auctionKey, int112(saleRate)));
    }

    /// @inheritdoc IAuctions
    function sellAmountByAuction(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        payable
        returns (uint112 saleRate)
    {
        saleRate = uint112(computeSaleRate(amount, auctionKey.config.auctionDuration()));

        sellByAuction(tokenId, auctionKey, saleRate);
    }

    /// @inheritdoc IAuctions
    function completeAuction(uint256 tokenId, AuctionKey memory auctionKey)
        public
        payable
        returns (uint128 creatorAmount, uint128 boostAmount)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_COMPLETE_AUCTION, tokenId, auctionKey)), (uint128, uint128));
    }

    /// @inheritdoc IAuctions
    function completeAuctionAndStartBoost(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint128 creatorAmount, uint128 boostAmount, uint112 boostRate, uint64 boostEndTime)
    {
        (creatorAmount, boostAmount) = completeAuction(tokenId, auctionKey);
        (boostRate, boostEndTime) = startBoost(auctionKey, boostAmount);
    }

    /// @inheritdoc IAuctions
    function startBoost(AuctionKey memory auctionKey)
        external
        payable
        returns (uint112 boostRate, uint64 boostEndTime)
    {
        bytes32 auctionId = auctionKey.toAuctionId();
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, auctionId);
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        return startBoost(auctionKey, amount);
    }

    /// @inheritdoc IAuctions
    function startBoost(AuctionKey memory auctionKey, uint128 amount)
        public
        payable
        returns (uint112 boostRate, uint64 boostEndTime)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_START_BOOST, auctionKey, amount)), (uint112, uint64));
    }

    /// @inheritdoc IAuctions
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount)
        public
        payable
        authorizedForNft(tokenId)
    {
        lock(abi.encode(CALL_TYPE_COLLECT_CREATOR_PROCEEDS, tokenId, auctionKey, recipient, amount));
    }

    /// @inheritdoc IAuctions
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient) external payable {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectCreatorProceeds(tokenId, auctionKey, recipient, amount);
    }

    /// @inheritdoc IAuctions
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount) external payable {
        collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
    }

    /// @inheritdoc IAuctions
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey) external payable {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
    }

    /// @inheritdoc IAuctions
    function executeVirtualOrdersAndGetSaleStatus(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 raisedAmount)
    {
        bytes32 orderSalt = _twammOrderSalt(tokenId, auctionKey.config);
        (saleRate, amountSold, remainingSellAmount, raisedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), orderSalt, auctionKey.toOrderKey());
    }

    /// @dev Derives the TWAMM order salt from immutable identity fields for a specific auction run.
    function _twammOrderSalt(uint256 tokenId, AuctionConfig config) internal pure returns (bytes32) {
        return EfficientHashLib.hash(tokenId, uint256(AuctionConfig.unwrap(config)));
    }

    /// @inheritdoc IAuctions
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        // the before update position hook shouldn't be taken into account here
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @dev Lock callback dispatcher for handling all of the supported auction actions.
    /// @param _lockId Lock id argument from BaseLocker callback.
    /// @param data ABI-encoded operation payload.
    /// @return result ABI-encoded return data for the requested operation.
    function handleLockData(uint256 _lockId, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            uint256 callType = abi.decode(data, (uint256));

            if (callType == CALL_TYPE_SELL_BY_AUCTION) {
                (, address caller, uint256 tokenId, AuctionKey memory auctionKey, int112 saleRateDelta) =
                    abi.decode(data, (uint256, address, uint256, AuctionKey, int112));
                bytes32 orderSalt = _twammOrderSalt(tokenId, auctionKey.config);

                uint128 amount = uint128(
                    uint256(
                        CORE.updateSaleRate({
                            twamm: TWAMM,
                            salt: orderSalt,
                            orderKey: auctionKey.toOrderKey(),
                            // cast is safe because of the earlier overflow checks
                            saleRateDelta: saleRateDelta
                        })
                    )
                );

                if (auctionKey.sellToken() == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
                } else {
                    ACCOUNTANT.payFrom(caller, auctionKey.sellToken(), amount);
                }

                emit AuctionFundsAdded(tokenId, auctionKey, uint112(saleRateDelta));
            } else if (callType == CALL_TYPE_COMPLETE_AUCTION) {
                (, uint256 tokenId, AuctionKey memory auctionKey) = abi.decode(data, (uint256, uint256, AuctionKey));
                bytes32 orderSalt = _twammOrderSalt(tokenId, auctionKey.config);

                uint64 auctionEndTime = auctionKey.config.endTime();
                if (block.timestamp < auctionEndTime) {
                    revert CannotCompleteAuctionBeforeEndOfAuction();
                }

                uint128 auctionProceeds = CORE.collectProceeds(TWAMM, orderSalt, auctionKey.toOrderKey());
                if (auctionProceeds == 0) revert NoProceedsToCompleteAuction();

                uint128 creatorAmount =
                    computeFee({amount: auctionProceeds, fee: uint64(auctionKey.config.creatorFee()) << 32});
                uint128 boostAmount = auctionProceeds - creatorAmount;

                if (creatorAmount != 0) {
                    (int256 delta0, int256 delta1) = auctionKey.config.isSellingToken1()
                        ? (int256(uint256(creatorAmount)), int256(0))
                        : (int256(0), int256(uint256(creatorAmount)));
                    CORE.updateSavedBalances({
                        token0: auctionKey.token0,
                        token1: auctionKey.token1,
                        salt: bytes32(tokenId),
                        delta0: delta0,
                        delta1: delta1
                    });
                }
                if (boostAmount != 0) {
                    bytes32 auctionId = auctionKey.toAuctionId();
                    (int256 delta0, int256 delta1) = auctionKey.config.isSellingToken1()
                        ? (int256(uint256(boostAmount)), int256(0))
                        : (int256(0), int256(uint256(boostAmount)));
                    CORE.updateSavedBalances({
                        token0: auctionKey.token0,
                        token1: auctionKey.token1,
                        salt: auctionId,
                        delta0: delta0,
                        delta1: delta1
                    });
                }

                emit AuctionCompleted(tokenId, auctionKey, creatorAmount, boostAmount);
                result = abi.encode(creatorAmount, boostAmount);
            } else if (callType == CALL_TYPE_COLLECT_CREATOR_PROCEEDS) {
                (, uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount) =
                    abi.decode(data, (uint256, uint256, AuctionKey, address, uint128));

                if (amount != 0) {
                    (int256 delta0, int256 delta1) = auctionKey.config.isSellingToken1()
                        ? (-int256(uint256(amount)), int256(0))
                        : (int256(0), -int256(uint256(amount)));
                    CORE.updateSavedBalances({
                        token0: auctionKey.token0,
                        token1: auctionKey.token1,
                        salt: bytes32(tokenId),
                        delta0: delta0,
                        delta1: delta1
                    });

                    ACCOUNTANT.withdraw(auctionKey.buyToken(), recipient, amount);
                    emit CreatorProceedsCollected(tokenId, auctionKey, recipient, amount);
                }
            } else if (callType == CALL_TYPE_START_BOOST) {
                (, AuctionKey memory auctionKey, uint128 boostAmount) = abi.decode(data, (uint256, AuctionKey, uint128));
                uint256 minBoostEndTime = block.timestamp + auctionKey.config.minBoostDuration();
                uint256 boostEndTimeRaw = nextValidTime({currentTime: block.timestamp, afterTime: minBoostEndTime});
                if (boostEndTimeRaw <= block.timestamp || boostEndTimeRaw > type(uint64).max) {
                    revert InvalidBoostEndTime();
                }
                uint64 boostEndTime = uint64(boostEndTimeRaw);

                uint112 boostRate;
                uint112 boostedAmount;
                uint256 duration = boostEndTime - block.timestamp;
                boostRate = uint112(
                    FixedPointMathLib.min((uint256(boostAmount) << 32) / duration, MAX_ABS_VALUE_SALE_RATE_DELTA)
                );
                (uint112 rate0, uint112 rate1) =
                    auctionKey.config.isSellingToken1() ? (boostRate, uint112(0)) : (uint112(0), boostRate);

                PoolKey memory graduationPoolKey = auctionKey.toGraduationPoolKey(BOOSTED_FEES);
                (uint112 amount0, uint112 amount1) =
                    CORE.addIncentives(graduationPoolKey, 0, boostEndTime, rate0, rate1);
                boostedAmount = auctionKey.config.isSellingToken1() ? amount0 : amount1;

                if (boostedAmount != 0) {
                    (int256 delta0, int256 delta1) = auctionKey.config.isSellingToken1()
                        ? (-int256(uint256(boostedAmount)), int256(0))
                        : (int256(0), -int256(uint256(boostedAmount)));
                    CORE.updateSavedBalances({
                        token0: auctionKey.token0,
                        token1: auctionKey.token1,
                        salt: auctionKey.toAuctionId(),
                        delta0: delta0,
                        delta1: delta1
                    });

                    emit BoostStarted(auctionKey, boostRate, boostEndTime);
                }

                result = abi.encode(boostRate, boostEndTime);
            } else {
                revert();
            }
        }
    }
}
