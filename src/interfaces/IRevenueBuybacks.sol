// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {IOrders} from "./IOrders.sol";
import {BuybacksState} from "../types/buybacksState.sol";
import {IExposedStorage} from "./IExposedStorage.sol";

/// @title Revenue Buybacks Interface
/// @notice Interface for automated revenue buyback orders using TWAMM (Time-Weighted Average Market Maker)
/// @dev Defines the interface for managing buyback orders for protocol revenue
interface IRevenueBuybacks is IExposedStorage {
    /// @notice Thrown when minimum order duration exceeds target order duration
    /// @dev This would prevent order creation since the condition order duration >= min order duration would not always be met
    error MinOrderDurationGreaterThanTargetOrderDuration();

    /// @notice Thrown when minimum order duration is set to zero
    /// @dev Orders cannot have zero duration, so this prevents invalid configurations
    error MinOrderDurationMustBeGreaterThanZero();

    /// @notice Thrown when roll is called and a token is not configured
    error TokenNotConfigured(address token);

    /// @notice Emitted when a token's buyback configuration is updated
    /// @param token The token being configured for buybacks
    /// @param state The state after configuring the token
    event Configured(address token, BuybacksState state);

    /// @notice The Orders contract used to create and manage TWAMM orders
    /// @dev All buyback orders are created through this contract
    function ORDERS() external view returns (IOrders);

    /// @notice The NFT token ID that represents all buyback orders created by this contract
    /// @dev A single NFT is minted and reused for all buyback orders to simplify management
    function NFT_ID() external view returns (uint256);

    /// @notice The token that is purchased with collected revenue
    /// @dev This is typically the protocol's governance or utility token
    function BUY_TOKEN() external view returns (address);

    /// @notice Approves the Orders contract to spend unlimited amounts of a token
    /// @dev Must be called at least once for each revenue token before creating buyback orders
    /// @param token The token to approve for spending by the Orders contract
    function approveMax(address token) external;

    /// @notice Withdraws leftover tokens from the contract (only callable by owner)
    /// @dev Used to recover tokens that may be stuck in the contract or to withdraw excess funds
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function take(address token, uint256 amount) external;

    /// @notice Collects the proceeds from a completed buyback order
    /// @dev Can be called by anyone at any time to collect proceeds from orders that have finished
    /// @param token The revenue token that was sold in the order
    /// @param fee The fee tier of the pool where the order was executed
    /// @param endTime The end time of the order to collect proceeds from
    /// @return proceeds The amount of buyToken received from the completed order
    function collect(address token, uint64 fee, uint256 endTime) external returns (uint128 proceeds);

    /// @notice Creates a new buyback order or extends an existing one with available revenue
    /// @dev Can be called by anyone to trigger the creation of buyback orders using collected revenue
    /// This function will either extend the current order (if conditions are met) or create a new order
    /// @param token The revenue token to use for creating the buyback order
    /// @return endTime The end time of the order that was created or extended
    /// @return saleRate The sale rate of the order (amount of token sold per second)
    function roll(address token) external returns (uint256 endTime, uint112 saleRate);

    /// @notice Configures buyback parameters for a revenue token (only callable by owner)
    /// @dev Sets the timing and fee parameters for automated buyback order creation
    /// @param token The revenue token to configure
    /// @param targetOrderDuration The target duration for new orders (in seconds)
    /// @param minOrderDuration The minimum duration threshold for creating new orders (in seconds)
    /// @param fee The fee tier for the buyback pool
    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee) external;
}
