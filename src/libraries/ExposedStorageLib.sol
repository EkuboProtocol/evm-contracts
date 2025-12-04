// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @dev This library includes some helper functions for calling IExposedStorage#sload and IExposedStorage#tload.
library ExposedStorageLib {
    function sload(IExposedStorage target, bytes32 slot) internal view returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x380eb4e0))
            mstore(4, slot)

            if iszero(staticcall(gas(), target, 0, 36, 0, 32)) { revert(0, 0) }

            result := mload(0)
        }
    }

    function sload(IExposedStorage target, bytes32 slot0, bytes32 slot1)
        internal
        view
        returns (bytes32 result0, bytes32 result1)
    {
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, shl(224, 0x380eb4e0))
            mstore(add(o, 4), slot0)
            mstore(add(o, 36), slot1)

            if iszero(staticcall(gas(), target, o, 68, o, 64)) { revert(0, 0) }

            result0 := mload(o)
            result1 := mload(add(o, 32))
        }
    }

    function sload(IExposedStorage target, bytes32 slot0, bytes32 slot1, bytes32 slot2)
        internal
        view
        returns (bytes32 result0, bytes32 result1, bytes32 result2)
    {
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, shl(224, 0x380eb4e0))
            mstore(add(o, 4), slot0)
            mstore(add(o, 36), slot1)
            mstore(add(o, 68), slot2)

            if iszero(staticcall(gas(), target, o, 100, o, 96)) { revert(0, 0) }

            result0 := mload(o)
            result1 := mload(add(o, 32))
            result2 := mload(add(o, 64))
        }
    }

    function tload(IExposedStorage target, bytes32 slot) internal view returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0xed832830))
            mstore(4, slot)

            if iszero(staticcall(gas(), target, 0, 36, 0, 32)) { revert(0, 0) }

            result := mload(0)
        }
    }

    // Overloads for StorageSlot type

    function sload(IExposedStorage target, StorageSlot slot) internal view returns (bytes32 result) {
        return sload(target, StorageSlot.unwrap(slot));
    }

    function sload(IExposedStorage target, StorageSlot slot0, StorageSlot slot1)
        internal
        view
        returns (bytes32 result0, bytes32 result1)
    {
        return sload(target, StorageSlot.unwrap(slot0), StorageSlot.unwrap(slot1));
    }

    function sload(IExposedStorage target, StorageSlot slot0, StorageSlot slot1, StorageSlot slot2)
        internal
        view
        returns (bytes32 result0, bytes32 result1, bytes32 result2)
    {
        return sload(target, StorageSlot.unwrap(slot0), StorageSlot.unwrap(slot1), StorageSlot.unwrap(slot2));
    }

    function tload(IExposedStorage target, StorageSlot slot) internal view returns (bytes32 result) {
        return tload(target, StorageSlot.unwrap(slot));
    }
}
