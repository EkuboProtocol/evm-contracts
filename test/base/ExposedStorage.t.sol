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
        SlotValues[] memory items = new SlotValues[](3);
        items[0] = SlotValues(slot0, value0);
        items[1] = SlotValues(slot1, value1);
        items[2] = SlotValues(slot2, value2);

        test_storage_write_many(items, false);
        test_storage_write_many(items, true);
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
