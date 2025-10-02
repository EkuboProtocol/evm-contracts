// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolId} from "../types/poolId.sol";

/// @title TWAMM Storage Layout
/// @notice Library providing functions to compute the storage locations for the TWAMM contract
/// @dev TWAMM uses a custom storage layout to avoid keccak's where possible.
///      For certain storage values, the pool id is used as a base offset and
///      we allocate the following relative offsets (starting from the pool id) as:
///        0: pool state
///        [REWARD_RATES_OFFSET, REWARD_RATES_OFFSET + 1]: global reward rates
///        [TIME_BITMAPS_OFFSET, TIME_BITMAPS_OFFSET + type(uint52).max]: initialized times bitmaps
///        [TIME_INFOS_OFFSET, TIME_INFOS_OFFSET + type(uint64).max]: time infos
///        [REWARD_RATES_BEFORE_OFFSET, REWARD_RATES_BEFORE_OFFSET + 2 * type(uint64).max]: reward rates before time
library TWAMMStorageLayout {
    uint256 internal constant REWARD_RATES_OFFSET = 1;
    uint256 internal constant TIME_BITMAPS_OFFSET = (1) + 2;
    uint256 internal constant TIME_INFOS_OFFSET = (1 + 2) + 1 << 52;
    uint256 internal constant REWARD_RATES_BEFORE_OFFSET = (1 + 2 + 1 << 52) + 1 << 64;

    /// @notice Computes the storage slot of the TWAMM pool state
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the TWAMM contract
    function twammPoolStateSlot(PoolId poolId) internal pure returns (bytes32 slot) {
        slot = PoolId.unwrap(poolId);
    }

    /// @notice Computes the first storage slot of the reward rates of a pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first of two consecutive storage slots in the TWAMM contract
    function poolRewardRatesSlot(PoolId poolId) internal pure returns (bytes32 firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, REWARD_RATES_OFFSET)
        }
    }

    /// @notice Computes the storage slot of the first word of an initialized times bitmap for a given pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first storage slot in the TWAMM contract
    /// @dev If the times used in bitmap operations do not fit into an uint64, storage slot collisions may happen!
    function poolInitializedTimesBitmapSlot(PoolId poolId) internal pure returns (bytes32 firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, TIME_BITMAPS_OFFSET)
        }
    }

    /// @notice Computes the storage slot of time info for a specific time
    /// @param poolId The unique identifier for the pool
    /// @param time The timestamp to query
    /// @return slot The storage slot in the TWAMM contract
    /// @dev If the time does not fit into an uint64, storage slot collisions may happen!
    function poolTimeInfosSlot(PoolId poolId, uint256 time) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, add(TIME_INFOS_OFFSET, time))
        }
    }

    /// @notice Computes the storage slot of the pool reward rates before a given time
    /// @param poolId The unique identifier for the pool
    /// @param time The time to query
    /// @return firstSlot The first of two consecutive storage slots in the TWAMM contract
    /// @dev If the time does not fit into an uint64, storage slot collisions may happen!
    function poolRewardRatesBeforeSlot(PoolId poolId, uint256 time) internal pure returns (bytes32 firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, add(REWARD_RATES_BEFORE_OFFSET, mul(time, 2)))
        }
    }

    /// @notice Computes the storage slot of the order state, followed by the order reward rate snapshot for a specific order
    /// @param owner The order owner
    /// @param salt The salt used for the order
    /// @param orderId The unique identifier for the order
    /// @return slot The storage slot of the order state in the TWAMM contract, followed by the storage slot of the order reward rate snapshot
    function orderStateSlotFollowedByOrderRewardRateSnapshotSlot(address owner, bytes32 salt, bytes32 orderId)
        internal
        pure
        returns (bytes32 slot)
    {
        assembly ("memory-safe") {
            mstore(0, salt)
            slot := add(owner, add(orderId, keccak256(0, 32)))
        }
    }
}
