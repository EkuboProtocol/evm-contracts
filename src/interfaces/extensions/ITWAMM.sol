// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";
import {PoolKey} from "../../types/poolKey.sol";
import {OrderKey} from "../../types/orderKey.sol";
import {PoolId} from "../../types/poolId.sol";

/// @title TWAMM Interface
/// @notice Interface for the Ekubo TWAMM Extension
/// @dev Extension for Ekubo Protocol that enables creation of DCA orders that are executed over time
interface ITWAMM is IExposedStorage, IExtension, ILocker, IForwardee {
    /// @notice Parameters for updating the sale rate of an order
    /// @dev Used when creating, modifying, or canceling orders
    struct UpdateSaleRateParams {
        /// @notice Unique salt for the order
        bytes32 salt;
        /// @notice Order key identifying the order
        OrderKey orderKey;
        /// @notice Change in sale rate (positive to increase, negative to decrease)
        int112 saleRateDelta;
    }

    /// @notice Parameters for collecting proceeds from an order
    /// @dev Used when withdrawing tokens purchased by an order
    struct CollectProceedsParams {
        /// @notice Unique salt for the order
        bytes32 salt;
        /// @notice Order key identifying the order
        OrderKey orderKey;
    }

    /// @notice Emitted when an order is updated
    /// @param owner Address of the order owner
    /// @param salt Unique salt for the order
    /// @param orderKey Order key identifying the order
    /// @param saleRateDelta Change in sale rate applied
    event OrderUpdated(address owner, bytes32 salt, OrderKey orderKey, int112 saleRateDelta);

    /// @notice Emitted when proceeds are withdrawn from an order
    /// @param owner Address of the order owner
    /// @param salt Unique salt for the order
    /// @param orderKey Order key identifying the order
    /// @param amount Amount of tokens withdrawn
    event OrderProceedsWithdrawn(address owner, bytes32 salt, OrderKey orderKey, uint128 amount);

    /// @notice Thrown when the number of orders at a time would overflow
    error TimeNumOrdersOverflow();

    /// @notice Thrown when tick spacing is not the maximum allowed value
    error TickSpacingMustBeMaximum();

    /// @notice Thrown when trying to modify an order that has already ended
    error OrderAlreadyEnded();

    /// @notice Thrown when order timestamps are invalid
    error InvalidTimestamps();

    /// @notice Thrown when trying to cancel an order with uncollected proceeds
    error MustCollectProceedsBeforeCanceling();

    /// @notice Thrown when sale rate delta exceeds maximum allowed value
    error MaxSaleRateDeltaPerTime();

    /// @notice Thrown when trying to operate on an uninitialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to execute virtual orders on a pool that does not use the TWAMM extension
    error InvalidPoolKey();

    /// @notice Gets the reward rate inside a time range for a specific token
    /// @dev Used to calculate how much of the buy token an order has earned
    /// @param poolId Unique identifier for the pool
    /// @param startTime Start time of the range
    /// @param endTime End time of the range
    /// @param isToken1 True if calculating for token1, false for token0
    /// @return result The reward rate inside the specified range
    function getRewardRateInside(PoolId poolId, uint256 startTime, uint256 endTime, bool isToken1)
        external
        view
        returns (uint256 result);

    /// @notice Locks core and executes virtual orders for the given pool key
    /// @dev The pool key must use this extension, which is checked in the locked callback
    /// @param poolKey Pool key identifying the pool
    function lockAndExecuteVirtualOrders(PoolKey memory poolKey) external;
}
