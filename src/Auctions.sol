// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {PoolKey} from "./types/poolKey.sol";
import {OrderKey} from "./types/orderKey.sol";
import {AuctionKey} from "./types/auctionKey.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {computeFee} from "./math/fee.sol";
import {nextValidTime} from "./math/time.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {BoostedFeesLib} from "./libraries/BoostedFeesLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @author Moody Salem <moody@ekubo.org>
/// @title Auctions
/// @notice Launchpad protocol for creating fair launches using Ekubo Protocol's TWAMM.
/// @dev Auction lifecycle:
/// 1. Mint auction NFT:
///    An auction is represented by an ERC721 token minted from this contract.
///    The owner (or approved operator) controls auction actions through `authorizedForNft`.
/// 2. Sell by auction:
///    `sellByAuction` initializes the TWAMM launch pool if needed and creates/increases the
///    per-auction TWAMM order keyed by `salt = bytes32(tokenId)`.
///    Sell tokens are pulled from the caller and paid into Core through the lock/accountant flow.
/// 3. Auction runs permissionlessly:
///    Anyone may execute virtual orders via TWAMM/Core mechanics; pricing/progress can be read with
///    `executeVirtualOrdersAndGetSaleStatus`.
/// 4. Complete auction (permissionless):
///    After end time, `completeAuction` collects TWAMM proceeds and splits them into:
///    - creator proceeds: saved into Core saved balances under `(token0, token1, salt=tokenId)`,
///    - boost proceeds: optionally converted into BoostedFees incentives for the graduation pool.
/// 5. Collect creator proceeds (owner/approved):
///    Authorized NFT controller calls `collectCreatorProceeds` overloads to withdraw saved creator
///    balances to any recipient or directly to the caller, optionally for partial amounts.
///    Collection debits saved balances and withdraws buy token via accountant in the same lock.
/// 6. Events:
///    `AuctionFundsAdded`, `AuctionCompleted`, and `CreatorProceedsCollected` mark each major stage.
contract Auctions is UsesCore, BaseLocker, BaseNonfungibleToken, PayableMulticallable {
    using CoreLib for *;
    using BoostedFeesLib for *;
    using TWAMMLib for *;
    using FlashAccountantLib for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;
    /// @notice The BoostedFees extension address
    address public immutable BOOSTED_FEES;

    uint8 private constant CALL_TYPE_SELL_BY_AUCTION = 0;
    uint8 private constant CALL_TYPE_COMPLETE_AUCTION = 1;
    uint8 private constant CALL_TYPE_COLLECT_CREATOR_PROCEEDS = 2;

    /// @notice The auction has not ended yet
    error CannotCompleteAuctionBeforeEndOfAuction();
    /// @notice The auction cannot be created because the computed sale rate delta is zero.
    error ZeroSaleRateDelta();
    /// @notice Thrown if the computed auction sale rate exceeds the type(int112).max
    error SaleRateTooLarge();
    /// @notice The auction cannot be completed because no proceeds are available.
    error NoProceedsToCompleteAuction();
    /// @notice Thrown when trying to add funds to an auction that has already started
    error AuctionAlreadyStarted();

    /// @notice Emitted when an auction is created and its TWAMM sale rate is set.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param saleRate The TWAMM sale rate delta applied for this auction.
    event AuctionFundsAdded(uint256 tokenId, AuctionKey auctionKey, uint112 saleRate);

    /// @notice Emitted when an auction is completed and proceeds are split.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param creatorAmount The amount reserved in saved balances for creator proceeds.
    /// @param boostRate The boost sale rate applied to the graduation pool incentives.
    /// @param boostEndTime The timestamp when the boost stops. The boost starts immediately.
    event AuctionCompleted(
        uint256 tokenId, AuctionKey auctionKey, uint128 creatorAmount, uint112 boostRate, uint64 boostEndTime
    );

    /// @notice Emitted when creator proceeds are collected from saved balances.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient The address receiving the collected proceeds.
    /// @param amount The amount of proceeds collected.
    event CreatorProceedsCollected(uint256 tokenId, AuctionKey auctionKey, address recipient, uint128 amount);

    constructor(address owner, ICore core, ITWAMM twamm, address boostedFees)
        UsesCore(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
    }

    /// @notice Sells tokens under an auction in the TWAMM launch pool for an existing auction NFT.
    /// @dev Caller must be owner or approved for `tokenId`. Pulls sell tokens from caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount The amount of sell token to auction.
    /// @return saleRate The TWAMM sale rate delta applied for this call.
    function sellByAuction(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        payable
        authorizedForNft(tokenId)
        returns (uint112 saleRate)
    {
        saleRate = abi.decode(
            lock(abi.encode(CALL_TYPE_SELL_BY_AUCTION, msg.sender, tokenId, auctionKey, amount)), (uint112)
        );
    }

    /// @notice Completes an ended auction by collecting TWAMM proceeds and splitting creator/boost shares.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return creatorAmount The portion saved for creator proceeds.
    /// @return boostRate The boost sale rate applied to graduation pool incentives (0 when no boost is added).
    /// @return boostEndTime The boost end timestamp (0 when no boost is added).
    function completeAuction(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint128 creatorAmount, uint112 boostRate, uint64 boostEndTime)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_COMPLETE_AUCTION, tokenId, auctionKey)), (uint128, uint112, uint64));
    }

    /// @notice Collects creator proceeds from saved balances to a chosen recipient.
    /// @dev This is the most explicit overload used by other collection overloads.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    /// @param amount Amount of buy token to collect.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount)
        public
        payable
        authorizedForNft(tokenId)
    {
        lock(abi.encode(CALL_TYPE_COLLECT_CREATOR_PROCEEDS, tokenId, auctionKey, recipient, amount));
    }

    /// @notice Collects all currently saved creator proceeds to a chosen recipient.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient)
        external
        payable
        authorizedForNft(tokenId)
    {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectCreatorProceeds(tokenId, auctionKey, recipient, amount);
    }

    /// @notice Collects a specific amount of creator proceeds to the caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount Amount of buy token to collect.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        payable
        authorizedForNft(tokenId)
    {
        collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
    }

    /// @notice Collects all currently saved creator proceeds to the caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        authorizedForNft(tokenId)
    {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(this), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint128 amount = auctionKey.config.isSellingToken1() ? saved0 : saved1;
        collectCreatorProceeds(tokenId, auctionKey, msg.sender, amount);
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
        payable
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(tokenId), auctionKey.toOrderKey());
    }

    /// @notice Lock callback dispatcher for selling by auction, completing auctions, and collecting creator proceeds.
    /// @param _lockId Lock id argument from BaseLocker callback.
    /// @param data ABI-encoded operation payload.
    /// @return result ABI-encoded return data for the requested operation.
    function handleLockData(uint256 _lockId, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            uint8 callType = abi.decode(data, (uint8));

            if (callType == CALL_TYPE_SELL_BY_AUCTION) {
                (, address caller, uint256 tokenId, AuctionKey memory auctionKey, uint128 amount) =
                    abi.decode(data, (uint8, address, uint256, AuctionKey, uint128));

                uint256 startTime = auctionKey.config.startTime();
                uint256 endTime = startTime + auctionKey.config.auctionDuration();

                if (startTime < block.timestamp) {
                    revert AuctionAlreadyStarted();
                }

                uint256 duration = endTime - startTime;
                uint256 saleRateDelta = computeSaleRate(amount, duration);
                // This will also happen if the specified duration is zero
                if (saleRateDelta == 0) {
                    revert ZeroSaleRateDelta();
                }

                if (saleRateDelta > uint112(type(int112).max)) {
                    revert SaleRateTooLarge();
                }

                PoolKey memory twammPoolKey = auctionKey.toLaunchPoolKey(address(TWAMM));
                if (!CORE.poolState(twammPoolKey.toPoolId()).isInitialized()) {
                    // The initial tick does not matter since we do not add liquidity to this pool
                    CORE.initializePool(twammPoolKey, 0);
                }

                amount = uint128(
                    uint256(
                        CORE.updateSaleRate({
                            twamm: TWAMM,
                            salt: bytes32(tokenId),
                            orderKey: auctionKey.toOrderKey(),
                            saleRateDelta: int112(int256(saleRateDelta))
                        })
                    )
                );

                if (auctionKey.sellToken() == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
                } else {
                    ACCOUNTANT.payFrom(caller, auctionKey.sellToken(), amount);
                }

                emit AuctionFundsAdded(tokenId, auctionKey, uint112(saleRateDelta));
                result = abi.encode(uint112(saleRateDelta));
            } else if (callType == CALL_TYPE_COMPLETE_AUCTION) {
                (, uint256 tokenId, AuctionKey memory auctionKey) = abi.decode(data, (uint8, uint256, AuctionKey));

                uint64 endTime = auctionKey.config.endTime();
                if (block.timestamp < endTime) {
                    revert CannotCompleteAuctionBeforeEndOfAuction();
                }

                OrderKey memory orderKey = auctionKey.toOrderKey();
                uint128 proceeds = CORE.collectProceeds(TWAMM, bytes32(tokenId), orderKey);
                if (proceeds == 0) {
                    revert NoProceedsToCompleteAuction();
                }

                uint128 creatorAmount = computeFee(proceeds, auctionKey.config.creatorFee());
                uint128 boostAmount = proceeds - creatorAmount;
                uint112 boostRate;
                uint64 boostEndTime;
                if (boostAmount != 0) {
                    PoolKey memory poolKey = auctionKey.toGraduationPoolKey(BOOSTED_FEES);

                    uint256 afterTime = block.timestamp + uint256(auctionKey.config.boostDuration());
                    boostEndTime = uint64(nextValidTime(block.timestamp, afterTime));
                    uint256 duration = boostEndTime - block.timestamp;
                    boostRate = uint112(computeSaleRate(boostAmount, duration));

                    (uint112 rate0, uint112 rate1) =
                        auctionKey.config.isSellingToken1() ? (boostRate, uint112(0)) : (uint112(0), boostRate);

                    (uint112 amount0, uint112 amount1) = CORE.addIncentives({
                        poolKey: poolKey, startTime: 0, endTime: boostEndTime, rate0: rate0, rate1: rate1
                    });

                    uint112 actualBoostedAmount = auctionKey.config.isSellingToken1() ? amount0 : amount1;
                    // we need to
                    creatorAmount += (boostAmount - actualBoostedAmount);
                }

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

                emit AuctionCompleted(tokenId, auctionKey, creatorAmount, boostRate, boostEndTime);
                result = abi.encode(creatorAmount, boostRate, boostEndTime);
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
                    emit CreatorProceedsCollected(tokenId, auctionKey, recipient, amount);
                }
            } else {
                revert();
            }
        }
    }
}
