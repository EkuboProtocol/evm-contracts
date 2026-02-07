// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolKey} from "./types/poolKey.sol";
import {createFullRangePoolConfig, createConcentratedPoolConfig} from "./types/poolConfig.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {AuctionConfig} from "./types/auctionConfig.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {computeFee} from "./math/fee.sol";
import {nextValidTime} from "./math/time.sol";
import {BoostedFeesLib} from "./libraries/BoostedFeesLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @author Moody Salem <moody@ekubo.org>
/// @title Auctions
/// @notice Launchpad protocol for creating fair launches using Ekubo Protocol's TWAMM
contract Auctions is UsesCore, BaseLocker, BaseNonfungibleToken {
    using CoreLib for *;
    using BoostedFeesLib for *;
    using TWAMMLib for *;
    using FlashAccountantLib for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;
    /// @notice The BoostedFees extension address
    address public immutable BOOSTED_FEES;
    /// @notice Creator collection fee represented as a 0.64 fixed-point fraction
    uint64 public immutable CREATOR_COLLECTION_FEE_X64;
    /// @notice Duration for the boost after graduation
    uint24 public immutable BOOST_DURATION;
    /// @notice Fee used for the graduation pool
    uint64 public immutable GRADUATION_POOL_FEE;
    /// @notice Tick spacing used for the graduation pool
    uint32 public immutable GRADUATION_POOL_TICK_SPACING;

    uint8 private constant CALL_TYPE_CREATE_AUCTION = 0;
    uint8 private constant CALL_TYPE_GRADUATE = 1;

    /// @notice The auction does not exist
    error AuctionNotFound();
    /// @notice The token cannot be the native token
    error CannotAuctionNativeToken();
    /// @notice The total amount sold cannot be decreased
    error TotalAmountSoldDecrease();
    /// @notice The auction has not ended yet
    error AuctionNotEnded();
    /// @notice Unexpected negative sale amount delta when increasing total sold amount
    error UnexpectedNegativeAmountDelta();

    constructor(
        address owner,
        ICore core,
        ITWAMM twamm,
        address boostedFees,
        uint64 creatorCollectionFeeX64,
        uint24 boostDuration,
        uint64 graduationPoolFee,
        uint32 graduationPoolTickSpacing
    )
        UsesCore(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
        CREATOR_COLLECTION_FEE_X64 = creatorCollectionFeeX64;
        BOOST_DURATION = boostDuration;
        GRADUATION_POOL_FEE = graduationPoolFee;
        GRADUATION_POOL_TICK_SPACING = graduationPoolTickSpacing;
    }

    function createAuction(uint256 tokenId, AuctionConfig config, uint128 totalAmountSold)
        external
        authorizedForNft(tokenId)
    {
        lock(abi.encode(CALL_TYPE_CREATE_AUCTION, msg.sender, tokenId, config, totalAmountSold));
    }

    function getLaunchPool(address token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token,
            config: createFullRangePoolConfig({_fee: 0, _extension: address(TWAMM)})
        });
    }

    function getSaleOrderKey(AuctionConfig config) public pure returns (OrderKey memory orderKey) {
        address token = config.token();
        uint64 startTime = config.startTime();
        uint64 endTime = startTime + config.duration();
        orderKey = OrderKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token,
            config: createOrderConfig({_fee: 0, _isToken1: true, _startTime: startTime, _endTime: endTime})
        });
    }

    function executeVirtualOrdersAndGetSaleStatus(uint256 tokenId, AuctionConfig config)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(tokenId), getSaleOrderKey(config));
    }

    function getGraduationPool(uint256, AuctionConfig config) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: config.token(),
            config: createConcentratedPoolConfig(
                GRADUATION_POOL_FEE, GRADUATION_POOL_TICK_SPACING, BOOSTED_FEES
            )
        });
    }

    function graduate(uint256 tokenId, AuctionConfig config)
        external
        authorizedForNft(tokenId)
        returns (uint128 proceeds, uint128 creatorAmount, uint128 boostAmount)
    {
        return abi.decode(
            lock(abi.encode(CALL_TYPE_GRADUATE, tokenId, config, ownerOf(tokenId))),
            (uint128, uint128, uint128)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint8 callType = abi.decode(data, (uint8));

        if (callType == CALL_TYPE_CREATE_AUCTION) {
            (
                ,
                address caller,
                uint256 tokenId,
                AuctionConfig config,
                uint128 totalAmountSold
            ) = abi.decode(data, (uint8, address, uint256, AuctionConfig, uint128));

            address configToken = config.token();
            if (configToken == NATIVE_TOKEN_ADDRESS) {
                revert CannotAuctionNativeToken();
            }

            uint64 startTime = config.startTime();
            uint64 endTime = startTime + config.duration();
            uint128 previousTotalAmountSold;
            (, uint256 amountSold, uint256 remainingSellAmount,) =
                TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(tokenId), getSaleOrderKey(config));
            previousTotalAmountSold = uint128(amountSold + remainingSellAmount);

            if (previousTotalAmountSold == 0) {
                PoolKey memory twammPoolKey = PoolKey({
                    token0: NATIVE_TOKEN_ADDRESS,
                    token1: configToken,
                    config: createFullRangePoolConfig({_fee: 0, _extension: address(TWAMM)})
                });

                if (!CORE.poolState(twammPoolKey.toPoolId()).isInitialized()) {
                    // The initial tick does not matter since we do not add liquidity
                    CORE.initializePool(twammPoolKey, 0);
                }
            } else if (totalAmountSold < previousTotalAmountSold) {
                revert TotalAmountSoldDecrease();
            }

            uint128 amountIncrease = totalAmountSold - previousTotalAmountSold;
            if (amountIncrease != 0) {
                uint64 realStart = uint64(FixedPointMathLib.max(block.timestamp, startTime));
                uint256 remainingDuration = endTime - realStart;
                uint112 saleRateDelta = uint112(computeSaleRate(amountIncrease, remainingDuration));

                int256 amountDelta = CORE.updateSaleRate({
                    twamm: TWAMM,
                    salt: bytes32(tokenId),
                    orderKey: OrderKey({
                        token0: NATIVE_TOKEN_ADDRESS,
                        token1: configToken,
                        config: createOrderConfig({_isToken1: true, _startTime: startTime, _endTime: endTime, _fee: 0})
                    }),
                    saleRateDelta: int112(int256(uint256(saleRateDelta)))
                });

                if (amountDelta < 0) {
                    revert UnexpectedNegativeAmountDelta();
                }
                if (amountDelta > 0) {
                    ACCOUNTANT.payFrom(caller, configToken, uint256(amountDelta));
                }
            }
        } else if (callType == CALL_TYPE_GRADUATE) {
            (, uint256 tokenId, AuctionConfig config, address creatorRecipient) =
                abi.decode(data, (uint8, uint256, AuctionConfig, address));

            uint64 startTime = config.startTime();
            uint64 endTime = startTime + config.duration();
            if (block.timestamp < endTime) {
                revert AuctionNotEnded();
            }

            OrderKey memory orderKey = getSaleOrderKey(config);
            uint128 proceeds = CORE.collectProceeds(TWAMM, bytes32(tokenId), orderKey);

            uint128 creatorAmount = computeFee(proceeds, CREATOR_COLLECTION_FEE_X64);
            uint128 boostAmount = proceeds - creatorAmount;

            if (creatorAmount != 0) {
                ACCOUNTANT.withdraw(NATIVE_TOKEN_ADDRESS, creatorRecipient, creatorAmount);
            }

            if (boostAmount != 0) {
                PoolKey memory poolKey = PoolKey({
                    token0: NATIVE_TOKEN_ADDRESS,
                    token1: config.token(),
                    config: createConcentratedPoolConfig(GRADUATION_POOL_FEE, GRADUATION_POOL_TICK_SPACING, BOOSTED_FEES)
                });

                uint256 afterTime = block.timestamp + uint256(BOOST_DURATION);
                uint64 boostEndTime = uint64(nextValidTime(block.timestamp, afterTime));
                uint64 currentTime = uint64(block.timestamp);
                uint256 duration = boostEndTime - currentTime;
                uint112 rate0 = uint112(computeSaleRate(boostAmount, duration));

                CORE.addIncentives(poolKey, 0, boostEndTime, rate0, 0);
            }

            result = abi.encode(proceeds, creatorAmount, boostAmount);
        } else {
            revert();
        }
    }
}
