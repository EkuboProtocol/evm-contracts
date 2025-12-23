// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {IExposedStorage} from "../../src/interfaces/IExposedStorage.sol";
import {ExposedStorage} from "../../src/base/ExposedStorage.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {PoolId} from "../../src/types/poolId.sol";

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

    function test_storage_write_many(SlotValues[] memory items, bool useTransient) public {
        TestTarget tt = new TestTarget();
        bytes memory slotsOnly = new bytes(items.length * 32);
        for (uint256 i = 0; i < items.length; i++) {
            bytes32 slot = items[i].slot;
            bytes32 value = items[i].value;
            assembly ("memory-safe") {
                tstore(slot, value)
                mstore(add(add(slotsOnly, 32), mul(i, 32)), slot)
            }
            if (useTransient) {
                tt.tstore(slot, value);
            } else {
                tt.sstore(slot, value);
            }
        }

        (bool success, bytes memory result) = address(tt)
            .call(
                abi.encodePacked(
                    useTransient ? IExposedStorage.tload.selector : IExposedStorage.sload.selector, slotsOnly
                )
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

    // Tests for StorageSlot overloads

    function test_storageSlot_sload_single(bytes32 slotValue, bytes32 value) public {
        TestTarget tt = new TestTarget();
        StorageSlot slot = StorageSlot.wrap(slotValue);

        assertEq(tt.sload(slot), 0);
        tt.sstore(slotValue, value);
        assertEq(tt.sload(slot), value);
    }

    function test_storageSlot_sload_two(bytes32 slotValue0, bytes32 slotValue1, bytes32 value0, bytes32 value1) public {
        TestTarget tt = new TestTarget();
        StorageSlot slot0 = StorageSlot.wrap(slotValue0);
        StorageSlot slot1 = StorageSlot.wrap(slotValue1);

        tt.sstore(slotValue0, value0);
        tt.sstore(slotValue1, value1);

        (bytes32 result0, bytes32 result1) = tt.sload(slot0, slot1);
        assertEq(result0, slotValue1 == slotValue0 ? value1 : value0);
        assertEq(result1, value1);
    }

    function test_storageSlot_sload_three(
        bytes32 slotValue0,
        bytes32 slotValue1,
        bytes32 slotValue2,
        bytes32 value0,
        bytes32 value1,
        bytes32 value2
    ) public {
        TestTarget tt = new TestTarget();
        StorageSlot slot0 = StorageSlot.wrap(slotValue0);
        StorageSlot slot1 = StorageSlot.wrap(slotValue1);
        StorageSlot slot2 = StorageSlot.wrap(slotValue2);

        tt.sstore(slotValue0, value0);
        tt.sstore(slotValue1, value1);
        tt.sstore(slotValue2, value2);

        (bytes32 result0, bytes32 result1, bytes32 result2) = tt.sload(slot0, slot1, slot2);
        assertEq(result0, slotValue0 == slotValue2 ? value2 : slotValue0 == slotValue1 ? value1 : value0);
        assertEq(result1, slotValue1 == slotValue2 ? value2 : value1);
        assertEq(result2, value2);
    }

    function test_storageSlot_tload_single(bytes32 slotValue, bytes32 value) public {
        TestTarget tt = new TestTarget();
        StorageSlot slot = StorageSlot.wrap(slotValue);

        assertEq(tt.tload(slot), 0);
        tt.tstore(slotValue, value);
        assertEq(tt.tload(slot), value);
    }

    function test_storageSlot_withCoreStorageLayout(bytes32 poolIdValue, bytes32 value) public {
        TestTarget tt = new TestTarget();
        PoolId poolId = PoolId.wrap(poolIdValue);

        // Demonstrate cleaner API: no need to unwrap StorageSlot
        StorageSlot slot = CoreStorageLayout.poolStateSlot(poolId);

        assertEq(tt.sload(slot), 0);
        tt.sstore(StorageSlot.unwrap(slot), value);
        assertEq(tt.sload(slot), value);
    }
}
