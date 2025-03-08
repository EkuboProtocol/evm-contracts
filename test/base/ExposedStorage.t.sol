// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExposedStorage} from "../../src/base/ExposedStorage.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";

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
    using ExposedStorageLib for *;

    function test_storage_writesCanBeRead(bytes32 slot, bytes32 value) public {
        TestTarget tt = new TestTarget();
        assertEq(tt.sload(slot), 0);
        tt.sstore(slot, value);
        assertEq(tt.sload(slot), value);
    }

    function test_storage_multiple_writesCanBeRead(
        bytes32 slot0,
        bytes32 slot1,
        bytes32 slot2,
        bytes32 value0,
        bytes32 value1,
        bytes32 value2
    ) public {
        // prevent slot1 and slot2 from being equal
        if (slot1 == slot0) {
            slot1 = bytes32(uint256(slot0) + 1);
        }
        if (slot2 == slot1 || slot2 == slot0) {
            slot2 = bytes32(uint256(slot1) + 1);
        }

        TestTarget tt = new TestTarget();
        assertEq(tt.sload(slot0), 0);
        assertEq(tt.sload(slot1), 0);
        assertEq(tt.sload(slot2), 0);

        tt.sstore(slot0, value0);
        tt.sstore(slot1, value1);
        tt.sstore(slot2, value2);

        (bytes32 v2, bytes32 v0, bytes32 v1) = tt.sload(slot2, slot0, slot1);
        assertEq(v0, value0);
        assertEq(v1, value1);
        assertEq(v2, value2);
    }

    function test_transientStorage_writesCanBeRead(bytes32 slot, bytes32 value) public {
        TestTarget tt = new TestTarget();
        assertEq(tt.tload(slot), 0);
        tt.tstore(slot, value);
        assertEq(tt.tload(slot), value);
    }
}
