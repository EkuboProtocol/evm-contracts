// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

abstract contract ExposedStorage is IExposedStorage {
    function sload() external view {
        assembly ("memory-safe") {
            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } { mstore(sub(i, 4), sload(calldataload(i))) }
            return(0, sub(calldatasize(), 4))
        }
    }

    function tload() external view {
        assembly ("memory-safe") {
            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } { mstore(sub(i, 4), tload(calldataload(i))) }
            return(0, sub(calldatasize(), 4))
        }
    }
}
