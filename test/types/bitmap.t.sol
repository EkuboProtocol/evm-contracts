// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Test} from "forge-std/Test.sol";
import {Bitmap} from "../../src/types/bitmap.sol";

contract BitmapTest is Test {
    function test_gas() public {
        vm.startSnapshotGas("toggle");
        Bitmap.wrap(0x8).toggle(3);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("isSet");
        Bitmap.wrap(0x8).isSet(3);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("leSetBit");
        Bitmap.wrap(type(uint256).max).leSetBit(9);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("geSetBit");
        Bitmap.wrap(type(uint256).max).geSetBit(9);
        vm.stopSnapshotGas();
    }

    function test_toggle(uint8 bit) public pure {
        assertEq(Bitmap.unwrap(Bitmap.wrap(0).toggle(bit)), 1 << bit);
        assertEq(Bitmap.unwrap(Bitmap.wrap(0).toggle(bit).toggle(bit)), 0);
        assertEq(Bitmap.unwrap(Bitmap.wrap(type(uint256).max).toggle(bit)), type(uint256).max - (1 << bit));
        assertEq(Bitmap.unwrap(Bitmap.wrap(type(uint256).max).toggle(bit).toggle(bit)), type(uint256).max);
    }

    function test_toggle_isSet(Bitmap bitmap, uint8 index) public pure {
        assertEq(bitmap.isSet(index), !bitmap.toggle(index).isSet(index));
    }

    function test_mask() public pure {
        uint8 index = 255;
        unchecked {
            assertEq((uint256(1) << (uint256(index) + 1)) - 1, type(uint256).max);
            assertEq((uint256(1) << (uint256(index) + 1)), 0);
        }
    }

    function test_leSetBit(Bitmap bitmap, uint8 index) public pure {
        uint256 prev = bitmap.leSetBit(index);
        if (prev != 0) {
            assertLe(prev - 1, index);
            assertTrue(bitmap.isSet(uint8(prev - 1)));
            for (uint256 i = index; i > prev; i--) {
                assertFalse(bitmap.isSet(uint8(i)));
            }
        } else {
            for (uint256 i = index; i >= 0;) {
                assertFalse(bitmap.isSet(uint8(i)));
                if (i == 0) break;
                i--;
            }
        }
    }

    function test_geSetBit(Bitmap bitmap, uint8 index) public pure {
        uint256 next = bitmap.geSetBit(index);

        if (next != 0) {
            assertGt(next, index);
            assertTrue(bitmap.isSet(uint8(next - 1)));
        } else {
            // for the following loop
            next = 256;
        }

        for (uint256 i = index; i < next - 1; i++) {
            assertFalse(bitmap.isSet(uint8(i)));
        }
    }
}
