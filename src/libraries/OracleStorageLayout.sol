// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StorageSlot} from "../types/storageSlot.sol";

/// @title Oracle Storage Layout
/// @notice Provides storage slot helpers for the Oracle contract
library OracleStorageLayout {
    /// @dev Generated using: cast keccak "Oracle#COUNTS_STORAGE_OFFSET"
    uint256 internal constant COUNTS_STORAGE_OFFSET =
        0x4621f066d26c296b34acf8cdc9e6c8b4fcd95344c44c7c37e3e1b9af2f2d59c3;

    /// @notice Computes the storage slot containing the counts for a token
    /// @param token The token address
    /// @return slot The storage slot in the Oracle contract
    function countsSlot(address token) internal pure returns (StorageSlot slot) {
        assembly ("memory-safe") {
            slot := add(token, COUNTS_STORAGE_OFFSET)
        }
    }

    /// @notice Computes the storage slot of a snapshot for a token at a given index
    /// @param token The token address
    /// @param index The snapshot index
    /// @return slot The storage slot in the Oracle contract
    function snapshotSlot(address token, uint256 index) internal pure returns (StorageSlot slot) {
        assembly ("memory-safe") {
            slot := or(shl(32, token), index)
        }
    }
}
