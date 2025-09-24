// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolId} from "../types/poolId.sol";

/// @title TWAMM Storage Layout
/// @notice Library providing functions to compute the storage locations for the TWAMM contract
/// @dev TWAMM uses a custom storage layout to avoid keccak's where possible.
///      For certain storage values, the pool id is used as a base offset and
///      we allocate the following relative offsets (starting from the pool id) as:
///        0: twamm pool state
///        1: auxiliary pool initialization flag
///        [REWARD_RATES_OFFSET]: pool reward rates
///        [TIME_BITMAPS_OFFSET + word]: initialized times bitmaps
///        [TIME_INFOS_OFFSET + time]: time infos
///        [REWARD_RATES_BEFORE_OFFSET + time]: reward rates before time
library TWAMMStorageLayout {
    uint256 internal constant REWARD_RATES_OFFSET = 0x01 << 224;
    uint256 internal constant TIME_BITMAPS_OFFSET = 0x02 << 224;
    uint256 internal constant TIME_INFOS_OFFSET = 0x03 << 224;
    uint256 internal constant REWARD_RATES_BEFORE_OFFSET = 0x04 << 224;

    /// @notice Computes the storage slot of the TWAMM pool state
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the TWAMM contract
    function twammPoolStateSlot(PoolId poolId) internal pure returns (bytes32 slot) {
        slot = PoolId.unwrap(poolId);
    }

    /// @notice Computes the storage slot of the auxiliary pool initialization flag
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the TWAMM contract
    function poolInitializationFlagSlot(PoolId poolId) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, 1)
        }
    }

    /// @notice Computes the storage slot of the pool reward rates
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the TWAMM contract (first of two consecutive slots for FeesPerLiquidity)
    function poolRewardRatesSlot(PoolId poolId) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, REWARD_RATES_OFFSET)
        }
    }

    /// @notice Computes the storage slot of the initialized times bitmap for a specific word
    /// @param poolId The unique identifier for the pool
    /// @param word The bitmap word index
    /// @return slot The storage slot in the TWAMM contract
    function poolInitializedTimesBitmapSlot(PoolId poolId, uint256 word) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, add(TIME_BITMAPS_OFFSET, word))
        }
    }

    /// @notice Computes the storage slot of time info for a specific time
    /// @param poolId The unique identifier for the pool
    /// @param time The timestamp to query
    /// @return slot The storage slot in the TWAMM contract
    function poolTimeInfosSlot(PoolId poolId, uint256 time) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, add(TIME_INFOS_OFFSET, time))
        }
    }

    /// @notice Computes the storage slot of reward rates before a specific time
    /// @param poolId The unique identifier for the pool
    /// @param time The timestamp to query
    /// @return slot The storage slot in the TWAMM contract (first of two consecutive slots for FeesPerLiquidity)
    function poolRewardRatesBeforeSlot(PoolId poolId, uint256 time) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            // FeesPerLiquidity takes 2 storage slots, so multiply time by 2
            slot := add(poolId, add(REWARD_RATES_BEFORE_OFFSET, mul(time, 2)))
        }
    }

    /// @notice Computes the storage slot of order state for a specific order
    /// @param owner The order owner
    /// @param salt The salt used for the order
    /// @param orderId The unique identifier for the order
    /// @return slot The storage slot in the TWAMM contract
    function orderStateSlot(address owner, bytes32 salt, bytes32 orderId) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, owner)
            mstore(add(free, 0x20), 4) // orderState mapping slot
            let ownerSaltHash := keccak256(free, 0x40)

            mstore(free, salt)
            mstore(add(free, 0x20), ownerSaltHash)
            let saltHash := keccak256(free, 0x40)

            mstore(free, orderId)
            mstore(add(free, 0x20), saltHash)
            slot := keccak256(free, 0x40)
        }
    }

    /// @notice Computes the storage slot of order reward rate snapshot for a specific order
    /// @param owner The order owner
    /// @param salt The salt used for the order
    /// @param orderId The unique identifier for the order
    /// @return slot The storage slot in the TWAMM contract
    function orderRewardRateSnapshotSlot(address owner, bytes32 salt, bytes32 orderId)
        internal
        pure
        returns (bytes32 slot)
    {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, owner)
            mstore(add(free, 0x20), 5) // orderRewardRateSnapshot mapping slot
            let ownerSaltHash := keccak256(free, 0x40)

            mstore(free, salt)
            mstore(add(free, 0x20), ownerSaltHash)
            let saltHash := keccak256(free, 0x40)

            mstore(free, orderId)
            mstore(add(free, 0x20), saltHash)
            slot := keccak256(free, 0x40)
        }
    }
}
