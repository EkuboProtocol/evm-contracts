// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

abstract contract ExposedStorage is IExposedStorage {
    function sload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 32)
        }
    }

    function tload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, tload(slot))
            return(0, 32)
        }
    }
}
