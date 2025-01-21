// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposedStorage} from "../../src/base/ExposedStorage.sol";

contract TestTarget is ExposedStorage {
    function sstore(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function tstore(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}

contract ExposedStorageTest is Test {
    function test_storage_writesCanBeRead(bytes32 slot, bytes32 value) public {
        TestTarget tt = new TestTarget();
        assertEq(tt.sload(slot), 0);
        tt.sstore(slot, value);
        assertEq(tt.sload(slot), value);
    }

    function test_transientStorage_writesCanBeRead(bytes32 slot, bytes32 value) public {
        TestTarget tt = new TestTarget();
        assertEq(tt.tload(slot), 0);
        tt.tstore(slot, value);
        assertEq(tt.tload(slot), value);
    }
}
