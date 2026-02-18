// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";
import {ITWAMM} from "./extensions/ITWAMM.sol";
import {PoolKey} from "../types/poolKey.sol";
import {AuctionKey} from "../types/auctionKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

/// @title Auctions Interface
/// @notice Interface for TWAMM-based token auction management.
interface IAuctions is IBaseNonfungibleToken {
    /// @notice The auction has not ended yet.
    error CannotCompleteAuctionBeforeEndOfAuction();
    /// @notice The auction cannot be created because the sale rate delta is zero.
    error ZeroSaleRateDelta();
    /// @notice The auction cannot be completed because no proceeds are available.
    error NoProceedsToCompleteAuction();
    /// @notice There is no valid future boost end time available.
    error InvalidBoostEndTime();
    /// @notice Thrown when trying to add funds to an auction that has already started.
    error AuctionAlreadyStarted();
    /// @notice The graduation pool tick spacing is invalid.
    error InvalidGraduationPoolTickSpacing();

    /// @notice Emitted when an auction is created and its TWAMM sale rate is set.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param saleRate The TWAMM sale rate of this auction.
    event AuctionFundsAdded(uint256 tokenId, AuctionKey auctionKey, uint112 saleRate);

    /// @notice Emitted when an auction is completed and proceeds are split.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param creatorAmount The amount reserved in saved balances for creator proceeds.
    /// @param boostAmount The amount reserved in saved balances for later boosting.
    event AuctionCompleted(uint256 tokenId, AuctionKey auctionKey, uint128 creatorAmount, uint128 boostAmount);

    /// @notice Emitted when a boost is started from saved boost proceeds.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param boostRate The boost sale rate applied to the graduation pool incentives.
    /// @param boostEndTime The timestamp when the boost stops.
    event BoostStarted(AuctionKey auctionKey, uint112 boostRate, uint64 boostEndTime);

    /// @notice Emitted when creator proceeds are collected from saved balances.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient The address receiving the collected proceeds.
    /// @param amount The amount of proceeds collected.
    event CreatorProceedsCollected(uint256 tokenId, AuctionKey auctionKey, address recipient, uint128 amount);

    /// @notice The TWAMM extension address.
    function TWAMM() external view returns (ITWAMM);

    /// @notice The BoostedFees extension address.
    function BOOSTED_FEES() external view returns (address);

    /// @notice Adds TWAMM sale rate for an auction NFT launch order.
    /// @dev Caller must be owner or approved for `tokenId`. Reverts if `block.timestamp > startTime`.
    /// Pulls the exact required sell-token amount from caller and updates order `salt = hash(tokenId, config)`.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param saleRate The TWAMM sale rate delta to add to the auction order.
    function sellByAuction(uint256 tokenId, AuctionKey memory auctionKey, uint112 saleRate) external payable;

    /// @notice Adds sell inventory for an auction NFT launch order by amount.
    /// @dev Computes `saleRate = (amount << 32) / auctionDuration` and forwards to the sale-rate entrypoint.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount The amount of sell token to auction.
    /// @return saleRate The TWAMM sale rate delta applied for this call.
    function sellAmountByAuction(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount)
        external
        payable
        returns (uint112 saleRate);

    /// @notice Completes an ended auction by collecting TWAMM proceeds and allocating creator/boost shares.
    /// @dev Permissionless. Reverts before end time or when no proceeds exist.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return creatorAmount The amount saved for creator proceeds keyed by `bytes32(tokenId)`.
    /// @return boostAmount The amount saved for future boosting keyed by `toAuctionId(auctionKey)`.
    function completeAuction(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint128 creatorAmount, uint128 boostAmount);

    /// @notice Completes an auction and immediately starts boost using the returned boost amount.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return creatorAmount The amount saved for creator proceeds keyed by `bytes32(tokenId)`.
    /// @return boostAmount The amount used to start boost from saved balances.
    /// @return boostRate The boost sale rate applied to graduation pool incentives.
    /// @return boostEndTime The boost end timestamp.
    function completeAuctionAndStartBoost(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint128 creatorAmount, uint128 boostAmount, uint112 boostRate, uint64 boostEndTime);

    /// @notice Starts boost on the graduation pool using all currently saved boost proceeds for an auction key.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return boostRate The boost sale rate applied to graduation pool incentives.
    /// @return boostEndTime The boost end timestamp.
    function startBoost(AuctionKey memory auctionKey) external payable returns (uint112 boostRate, uint64 boostEndTime);

    /// @notice Starts boost on the graduation pool using a specific amount from saved boost proceeds.
    /// @dev Permissionless. Reverts if the requested amount is not available in saved boost balances.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount The amount of saved boost proceeds to use for this boost call.
    /// @return boostRate The boost sale rate applied to graduation pool incentives.
    /// @return boostEndTime The boost end timestamp.
    function startBoost(AuctionKey memory auctionKey, uint128 amount)
        external
        payable
        returns (uint112 boostRate, uint64 boostEndTime);

    /// @notice Collects creator proceeds from saved balances to a chosen recipient.
    /// @dev This is the most explicit overload used by other collection overloads.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    /// @param amount Amount of buy token to collect.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient, uint128 amount)
        external
        payable;

    /// @notice Collects all currently saved creator proceeds to a chosen recipient.
    /// @dev Reads the buy-token side of saved balances keyed by `bytes32(tokenId)`.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param recipient Address to receive proceeds.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, address recipient) external payable;

    /// @notice Collects a specific amount of creator proceeds to the caller.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @param amount Amount of buy token to collect.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey, uint128 amount) external payable;

    /// @notice Collects all currently saved creator proceeds to the caller.
    /// @dev Reads the buy-token side of saved balances keyed by `bytes32(tokenId)`.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    function collectCreatorProceeds(uint256 tokenId, AuctionKey memory auctionKey) external payable;

    /// @notice Executes TWAMM virtual orders and returns current sale status for an auction.
    /// @param tokenId The auction NFT token id.
    /// @param auctionKey The auction key defining tokens and config.
    /// @return saleRate Current sale rate of the underlying TWAMM order.
    /// @return amountSold Total amount sold so far.
    /// @return remainingSellAmount Remaining amount of sell token.
    /// @return raisedAmount Current total proceeds of the auction.
    function executeVirtualOrdersAndGetSaleStatus(uint256 tokenId, AuctionKey memory auctionKey)
        external
        payable
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 raisedAmount);

    /// @notice Initializes the provided pool if not yet initialized and returns its sqrt ratio.
    /// @param poolKey The pool key to check and potentially initialize.
    /// @param tick The initialization tick to use when the pool is not initialized.
    /// @return initialized Whether this call initialized the pool.
    /// @return sqrtRatio The current or newly initialized sqrt ratio.
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Initializes the launch pool for the given auction key if not yet initialized.
    /// @param auctionKey The auction key used to derive the launch pool key.
    /// @param tick The initialization tick to use when the pool is not initialized.
    /// @return initialized Whether this call initialized the pool.
    /// @return sqrtRatio The current or newly initialized sqrt ratio.
    function maybeInitializeLaunchPool(AuctionKey memory auctionKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Initializes the graduation pool for the given auction key if not yet initialized.
    /// @param auctionKey The auction key used to derive the graduation pool key.
    /// @param tick The initialization tick to use when the pool is not initialized.
    /// @return initialized Whether this call initialized the pool.
    /// @return sqrtRatio The current or newly initialized sqrt ratio.
    function maybeInitializeGraduationPool(AuctionKey memory auctionKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);
}
