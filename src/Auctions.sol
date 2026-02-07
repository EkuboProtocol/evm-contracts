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
    uint8 private constant CALL_TYPE_COLLECT_CREATOR_PROCEEDS = 2;

    /// @notice The auction has not ended yet
    error CannotGraduateBeforeEndOfAuction();

    event AuctionCreated(uint256 indexed tokenId, AuctionKey auctionKey, uint128 amount, uint112 saleRate);
    event AuctionGraduated(uint256 indexed tokenId, AuctionKey auctionKey, uint128 creatorAmount, uint128 boostAmount);
    event CreatorProceedsCollected(
        uint256 indexed tokenId, AuctionKey auctionKey, address indexed recipient, uint128 amount
    );

    constructor(address owner, ICore core, ITWAMM twamm, address boostedFees)
        UsesCore(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
    }

    /// @notice Creates an auction order in the TWAMM launch pool for an existing auction NFT.
    /// @dev Caller must be owner or approved for `tokenId`. Pulls sell tokens from caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount The amount of sell token to auction.
    function createAuction(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        authorizedForNft(tokenId)
    {
        lock(abi.encode(CALL_TYPE_CREATE_AUCTION, msg.sender, tokenId, auctionKey, amount));
    }

    /// @notice Graduates an ended auction by collecting TWAMM proceeds and splitting creator/boost shares.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return creatorAmount The portion saved for creator proceeds.
    /// @return boostAmount The portion routed to boosted-fee incentives.
    function graduate(uint256 tokenId, AuctionKey memory auctionKey)
        external
        returns (uint128 creatorAmount, uint128 boostAmount)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_GRADUATE, tokenId, auctionKey)), (uint128, uint128));
    }

    /// @notice Collects creator proceeds from saved balances to a chosen recipient.
    /// @dev This is the most explicit overload used by other collection overloads.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    /// @param amount Amount of buy token to collect.
    /// @return collectedAmount The amount collected.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount)
        public
        authorizedForNft(tokenId)
        returns (uint128 collectedAmount)
    {
        collectedAmount = abi.decode(
            lock(abi.encode(CALL_TYPE_COLLECT_CREATOR_PROCEEDS, tokenId, auctionKey, recipient, amount)), (uint128)
        );
    }

    /// @notice Collects all currently saved creator proceeds to a chosen recipient.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    /// @return collectedAmount The amount collected.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient)
        external
        authorizedForNft(tokenId)
        returns (uint128 collectedAmount)
    {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectedAmount = collectCreatorProceeds(tokenId, auctionKey, recipient, amount);
    }

    /// @notice Collects a specific amount of creator proceeds to the caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount Amount of buy token to collect.
    /// @return collectedAmount The amount collected.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        authorizedForNft(tokenId)
        returns (uint128 collectedAmount)
    {
        collectedAmount = collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
    }

    /// @notice Collects all currently saved creator proceeds to the caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return collectedAmount The amount collected.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey)
        external
        authorizedForNft(tokenId)
        returns (uint128 collectedAmount)
    {
        (uint128 saved0, uint128 saved1) = CORE.savedBalances(
            address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId)
        );
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectedAmount = collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
    }

    /// @notice Executes TWAMM virtual orders and returns current sale status for an auction.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return saleRate Current sale rate of the underlying TWAMM order.
    /// @return amountSold Total amount sold so far.
    /// @return remainingSellAmount Remaining amount of sell token.
    /// @return purchasedAmount Proceeds available to collect.
    function executeVirtualOrdersAndGetSaleStatus(uint256 tokenId, AuctionKey memory auctionKey)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(tokenId), auctionKey.toOrderKey());
    }

    /// @notice Lock callback dispatcher for creating auctions, graduating, and collecting creator proceeds.
    /// @param lockId Lock id argument from BaseLocker callback.
    /// @param data ABI-encoded operation payload.
    /// @return result ABI-encoded return data for the requested operation.
    function handleLockData(uint256 lockId, bytes memory data) internal override returns (bytes memory result) {
        lockId;
        uint8 callType = abi.decode(data, (uint8));

        if (callType == CALL_TYPE_CREATE_AUCTION) {
            (, address caller, uint256 tokenId, AuctionKey memory auctionKey, uint128 amount) =
                abi.decode(data, (uint8, address, uint256, AuctionKey, uint128));

            uint64 startTime = uint64(auctionKey.config.startTime());
            uint64 endTime = auctionKey.config.endTime();

            PoolKey memory twammPoolKey = auctionKey.toLaunchPoolKey(address(TWAMM));
            if (!CORE.poolState(twammPoolKey.toPoolId()).isInitialized()) {
                // The initial tick does not matter since we do not add liquidity
                CORE.initializePool(twammPoolKey, 0);
            }

            uint64 realStart = uint64(FixedPointMathLib.max(block.timestamp, startTime));
            uint256 remainingDuration = endTime - realStart;
            uint112 saleRateDelta = uint112(computeSaleRate(amount, remainingDuration));

            int256 amountDelta = CORE.updateSaleRate({
                twamm: TWAMM,
                salt: bytes32(tokenId),
                orderKey: auctionKey.toOrderKey(),
                saleRateDelta: int112(int256(uint256(saleRateDelta)))
            });

            if (amountDelta != 0) {
                ACCOUNTANT.payFrom(caller, auctionKey.sellToken(), uint256(amountDelta));
            }
            emit AuctionCreated(tokenId, auctionKey, amount, saleRateDelta);
        } else if (callType == CALL_TYPE_GRADUATE) {
            (, uint256 tokenId, AuctionKey memory auctionKey) = abi.decode(data, (uint8, uint256, AuctionKey));

            uint64 endTime = auctionKey.config.endTime();
            if (block.timestamp < endTime) {
                revert CannotGraduateBeforeEndOfAuction();
            }

            OrderKey memory orderKey = auctionKey.toOrderKey();
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
                PoolKey memory poolKey = auctionKey.toGraduationPoolKey(BOOSTED_FEES);

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

            emit AuctionGraduated(tokenId, auctionKey, creatorAmount, boostAmount);
            result = abi.encode(creatorAmount, boostAmount);
        } else if (callType == CALL_TYPE_COLLECT_CREATOR_PROCEEDS) {
            (, uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount) =
                abi.decode(data, (uint8, uint256, AuctionKey, address, uint128));

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
            }

            emit CreatorProceedsCollected(tokenId, auctionKey, recipient, amount);
            result = abi.encode(amount);
        } else {
            revert();
        }
    }
}
