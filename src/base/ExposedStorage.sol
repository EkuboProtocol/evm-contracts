// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// Exposes all the storage of a contract via view methods.
// Absent https://eips.ethereum.org/EIPS/eip-2330 this makes it easier to access specific pieces of state in the inheriting contract.
abstract contract ExposedStorage {
    function sload(bytes32 slot) external view returns (bytes32 result) {
        assembly ("memory-safe") {
            result := sload(slot)
        }
    }

    function tload(bytes32 slot) external view returns (bytes32 result) {
        assembly ("memory-safe") {
            result := tload(slot)
        }
    }
}
