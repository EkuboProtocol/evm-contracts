// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {PoolKey} from "./types/poolKey.sol";
import {OrderKey} from "./types/orderKey.sol";
import {AuctionKey} from "./types/auctionKey.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {UsesCore} from "./base/UsesCore.sol";
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

    uint8 private constant CALL_TYPE_CREATE_AUCTION = 0;
    uint8 private constant CALL_TYPE_GRADUATE = 1;

    /// @notice Invalid auction key token ordering
    error InvalidTokenOrder();
    /// @notice The total amount sold cannot be decreased
    error TotalAmountSoldDecrease();
    /// @notice The auction has not ended yet
    error AuctionNotEnded();
    /// @notice Unexpected negative sale amount delta when increasing total sold amount
    error UnexpectedNegativeAmountDelta();

    constructor(address owner, ICore core, ITWAMM twamm, address boostedFees)
        UsesCore(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
    }

    function createAuction(uint256 tokenId, AuctionKey memory auctionKey, uint128 totalAmountSold)
        external
        authorizedForNft(tokenId)
    {
        lock(abi.encode(CALL_TYPE_CREATE_AUCTION, msg.sender, tokenId, auctionKey, totalAmountSold));
    }

    function graduate(uint256 tokenId, AuctionKey memory auctionKey)
        external
        returns (uint128 creatorAmount, uint128 boostAmount)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_GRADUATE, tokenId, auctionKey)), (uint128, uint128));
    }

    function getLaunchPool(AuctionKey memory auctionKey) public view returns (PoolKey memory poolKey) {
        _validateAuctionKey(auctionKey);
        poolKey = auctionKey.toLaunchPoolKey(address(TWAMM));
    }

    function getSaleOrderKey(AuctionKey memory auctionKey) public pure returns (OrderKey memory orderKey) {
        _validateAuctionKey(auctionKey);
        orderKey = auctionKey.toOrderKey();
    }

    function executeVirtualOrdersAndGetSaleStatus(uint256 tokenId, AuctionKey memory auctionKey)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(
                address(this), bytes32(tokenId), getSaleOrderKey(auctionKey)
            );
    }

    function getGraduationPool(uint256, AuctionKey memory auctionKey) public view returns (PoolKey memory poolKey) {
        _validateAuctionKey(auctionKey);
        poolKey = auctionKey.toGraduationPoolKey(BOOSTED_FEES);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint8 callType = abi.decode(data, (uint8));

        if (callType == CALL_TYPE_CREATE_AUCTION) {
            (, address caller, uint256 tokenId, AuctionKey memory auctionKey, uint128 totalAmountSold) =
                abi.decode(data, (uint8, address, uint256, AuctionKey, uint128));

            _validateAuctionKey(auctionKey);

            uint64 startTime = uint64(auctionKey.config.startTime());
            uint64 endTime = auctionKey.config.endTime();
            uint128 previousTotalAmountSold;

            PoolKey memory twammPoolKey = getLaunchPool(auctionKey);
            if (!CORE.poolState(twammPoolKey.toPoolId()).isInitialized()) {
                // The initial tick does not matter since we do not add liquidity
                CORE.initializePool(twammPoolKey, 0);
            } else {
                (, uint256 amountSold, uint256 remainingSellAmount,) = TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(
                    address(this), bytes32(tokenId), getSaleOrderKey(auctionKey)
                );
                previousTotalAmountSold = uint128(amountSold + remainingSellAmount);
            }

            if (totalAmountSold < previousTotalAmountSold) {
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
                    orderKey: getSaleOrderKey(auctionKey),
                    saleRateDelta: int112(int256(uint256(saleRateDelta)))
                });

                if (amountDelta < 0) {
                    revert UnexpectedNegativeAmountDelta();
                }
                if (amountDelta > 0) {
                    ACCOUNTANT.payFrom(caller, auctionKey.sellToken(), uint256(amountDelta));
                }
            }
        } else if (callType == CALL_TYPE_GRADUATE) {
            (, uint256 tokenId, AuctionKey memory auctionKey) = abi.decode(data, (uint8, uint256, AuctionKey));

            _validateAuctionKey(auctionKey);

            uint64 startTime = uint64(auctionKey.config.startTime());
            uint64 endTime = auctionKey.config.endTime();
            if (block.timestamp < endTime) {
                revert AuctionNotEnded();
            }

            OrderKey memory orderKey = getSaleOrderKey(auctionKey);
            uint128 proceeds = CORE.collectProceeds(TWAMM, bytes32(tokenId), orderKey);

            uint128 creatorAmount = computeFee(proceeds, auctionKey.config.creatorFee());
            uint128 boostAmount = proceeds - creatorAmount;

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
                PoolKey memory poolKey = getGraduationPool(tokenId, auctionKey);

                uint256 afterTime = block.timestamp + uint256(auctionKey.config.boostDuration());
                uint64 boostEndTime = uint64(nextValidTime(block.timestamp, afterTime));
                uint64 currentTime = uint64(block.timestamp);
                uint256 duration = boostEndTime - currentTime;
                uint112 rate = uint112(computeSaleRate(boostAmount, duration));

                if (auctionKey.buyToken() == poolKey.token0) {
                    CORE.addIncentives(poolKey, 0, boostEndTime, rate, 0);
                } else {
                    CORE.addIncentives(poolKey, 0, boostEndTime, 0, rate);
                }
            }

            result = abi.encode(creatorAmount, boostAmount);
        } else {
            revert();
        }
    }

    function _validateAuctionKey(AuctionKey memory auctionKey) private pure {
        if (auctionKey.token0 >= auctionKey.token1) {
            revert InvalidTokenOrder();
        }
    }
}
