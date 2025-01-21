// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

abstract contract ExposedStorage is IExposedStorage {
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
