// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {OrderKey} from "../types/orderKey.sol";
import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";

/// @title Orders Interface
/// @notice Interface for managing TWAMM (Time-Weighted Average Market Maker) orders as NFTs
/// @dev Defines the interface for creating, modifying, and collecting proceeds from long-term orders
interface IOrders is IBaseNonfungibleToken {
    /// @notice Thrown when trying to modify an order that has already ended
    error OrderAlreadyEnded();

    /// @notice Thrown when the calculated sale rate exceeds the maximum allowed
    error MaxSaleRateExceeded();

    /// @notice Mints a new NFT and creates a TWAMM order
    /// @param orderKey Key identifying the order parameters
    /// @param amount Amount of tokens to sell over the order duration
    /// @param maxSaleRate Maximum acceptable sale rate (for slippage protection)
    /// @return id The newly minted NFT token ID
    /// @return saleRate The calculated sale rate for the order
    function mintAndIncreaseSellAmount(OrderKey memory orderKey, uint112 amount, uint112 maxSaleRate)
        external
        payable
        returns (uint256 id, uint112 saleRate);

    /// @notice Increases the sell amount for an existing TWAMM order
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @param amount Additional amount of tokens to sell
    /// @param maxSaleRate Maximum acceptable sale rate (for slippage protection)
    /// @return saleRate The calculated sale rate for the additional amount
    function increaseSellAmount(uint256 id, OrderKey memory orderKey, uint128 amount, uint112 maxSaleRate)
        external
        payable
        returns (uint112 saleRate);

    /// @notice Decreases the sale rate for an existing TWAMM order
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @param saleRateDecrease Amount to decrease the sale rate by
    /// @param recipient Address to receive the refunded tokens
    /// @return refund Amount of tokens refunded
    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease, address recipient)
        external
        payable
        returns (uint112 refund);

    /// @notice Decreases the sale rate for an existing TWAMM order (refund to msg.sender)
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @param saleRateDecrease Amount to decrease the sale rate by
    /// @return refund Amount of tokens refunded
    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease)
        external
        payable
        returns (uint112 refund);

    /// @notice Collects the proceeds from a TWAMM order
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @param recipient Address to receive the proceeds
    /// @return proceeds Amount of tokens collected as proceeds
    function collectProceeds(uint256 id, OrderKey memory orderKey, address recipient)
        external
        payable
        returns (uint128 proceeds);

    /// @notice Collects the proceeds from a TWAMM order (to msg.sender)
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @return proceeds Amount of tokens collected as proceeds
    function collectProceeds(uint256 id, OrderKey memory orderKey) external payable returns (uint128 proceeds);

    /// @notice Executes virtual orders and returns current order information
    /// @dev Updates the order state by executing any pending virtual orders
    /// @param id The NFT token ID representing the order
    /// @param orderKey Key identifying the order parameters
    /// @return saleRate Current sale rate of the order
    /// @return amountSold Total amount sold so far
    /// @return remainingSellAmount Amount remaining to be sold
    /// @return purchasedAmount Amount of tokens purchased (proceeds available)
    function executeVirtualOrdersAndGetCurrentOrderInfo(uint256 id, OrderKey memory orderKey)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount);
}
