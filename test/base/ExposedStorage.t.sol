// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IExposedStorage} from "../../src/interfaces/IExposedStorage.sol";
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

    struct SlotValues {
        bytes32 slot;
        bytes32 value;
    }

    function test_storage_write_many(SlotValues[] memory items, bool transient) public {
        TestTarget tt = new TestTarget();
        bytes memory slotsOnly = new bytes(items.length * 32);
        for (uint256 i = 0; i < items.length; i++) {
            bytes32 slot = items[i].slot;
            bytes32 value = items[i].value;
            assembly ("memory-safe") {
                tstore(slot, value)
                mstore(add(add(slotsOnly, 32), mul(i, 32)), slot)
            }
            if (transient) {
                tt.tstore(slot, value);
            } else {
                tt.sstore(slot, value);
            }
        }

        (bool success, bytes memory result) = address(tt).call(
            abi.encodePacked(transient ? IExposedStorage.tload.selector : IExposedStorage.sload.selector, slotsOnly)
        );

        assertTrue(success);
        assertEq(result.length, slotsOnly.length);
        for (uint256 i = 0; i < items.length; i++) {
            bytes32 slot = items[i].slot;
            bytes32 expectedValue;
            bytes32 receivedValue;
            assembly ("memory-safe") {
                expectedValue := tload(slot)
                receivedValue := mload(add(add(result, 32), mul(i, 32)))
            }
            assertEq(expectedValue, receivedValue);
        }
    }

    function test_transientStorage_writesCanBeRead(bytes32 slot, bytes32 value) public {
        TestTarget tt = new TestTarget();
        assertEq(tt.tload(slot), 0);
        tt.tstore(slot, value);
        assertEq(tt.tload(slot), value);
    }
}
