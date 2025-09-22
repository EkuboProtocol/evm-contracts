// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IOrders} from "./IOrders.sol";

/// @notice Configuration and state for revenue buyback orders for a specific token
/// @dev Tracks the parameters and timing for automated buyback order creation
struct BuybacksState {
    /// @notice Target duration for new orders (in seconds)
    /// @dev New orders will be placed for the minimum duration that is larger than this target
    uint32 targetOrderDuration;
    /// @notice Minimum duration threshold for order creation (in seconds)
    /// @dev New orders will be created only if the last order duration is less than this threshold
    uint32 minOrderDuration;
    /// @notice Fee tier of the pool on which orders are placed
    /// @dev Expressed as a fraction where higher values represent higher fees
    uint64 fee;
    /// @notice End time of the last order that was created (timestamp)
    uint32 lastEndTime;
    /// @notice Duration of the last order that was created (in seconds)
    uint32 lastOrderDuration;
    /// @notice Fee tier of the last order that was created
    uint64 lastFee;
}

/// @title Revenue Buybacks Interface
/// @notice Interface for automated revenue buyback orders using TWAMM (Time-Weighted Average Market Maker)
/// @dev Defines the interface for managing buyback orders for protocol revenue
interface IRevenueBuybacks {
    /// @notice Thrown when minimum order duration exceeds target order duration
    /// @dev This would prevent orders from being created since the condition would never be met
    error MinOrderDurationGreaterThanTargetOrderDuration();

    /// @notice Thrown when minimum order duration is set to zero
    /// @dev Orders cannot have zero duration, so this prevents invalid configurations
    error MinOrderDurationMustBeGreaterThanZero();

    /// @notice Emitted when a token's buyback configuration is updated
    /// @param token The token being configured for buybacks
    /// @param targetOrderDuration The target duration for new orders
    /// @param minOrderDuration The minimum duration threshold for creating new orders
    /// @param fee The fee tier for the buyback pool
    event Configured(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee);

    /// @notice The Orders contract used to create and manage TWAMM orders
    /// @dev All buyback orders are created through this contract
    function ORDERS() external view returns (IOrders);

    /// @notice The NFT token ID that represents all buyback orders created by this contract
    /// @dev A single NFT is minted and reused for all buyback orders to simplify management
    function NFT_ID() external view returns (uint256);

    /// @notice The token that is purchased with collected revenue
    /// @dev This is typically the protocol's governance or utility token
    function BUY_TOKEN() external view returns (address);

    /// @notice Maps each revenue token to its buyback configuration and state
    /// @dev Tracks the parameters and timing for automated buyback order creation
    function states(address token)
        external
        view
        returns (
            uint32 targetOrderDuration,
            uint32 minOrderDuration,
            uint64 fee,
            uint32 lastEndTime,
            uint32 lastOrderDuration,
            uint64 lastFee
        );

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
