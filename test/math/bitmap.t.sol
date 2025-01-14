// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Bitmap} from "../../src/math/bitmap.sol";

contract BitmapTest is Test {
    function test_toggle(uint8 bit) public pure {
        assertEq(Bitmap.unwrap(Bitmap.wrap(0).toggle(bit)), 1 << bit);
        assertEq(Bitmap.unwrap(Bitmap.wrap(0).toggle(bit).toggle(bit)), 0);
        assertEq(Bitmap.unwrap(Bitmap.wrap(type(uint256).max).toggle(bit)), type(uint256).max - (1 << bit));
        assertEq(Bitmap.unwrap(Bitmap.wrap(type(uint256).max).toggle(bit).toggle(bit)), type(uint256).max);
    }

    function test_toggle_isSet(Bitmap bitmap, uint8 index) public pure {
        assertEq(bitmap.isSet(index), !bitmap.toggle(index).isSet(index));
    }

    function test_ltSetBit(Bitmap bitmap, uint8 index) public pure {
        index = uint8(bound(index, 1, 255));
        uint8 prev = bitmap.ltSetBit(index);
        assertLt(prev, index);
        assertTrue(bitmap.isSet(prev) || prev == 0);
        for (uint8 i = index - 1; i > prev; i--) {
            assertFalse(bitmap.isSet(i));
        }
    }

    function test_geSetBit(Bitmap bitmap, uint8 index) public pure {
        uint8 next = bitmap.geSetBit(index);
        assertGe(next, index);
        assertTrue(bitmap.isSet(next) || next == 255);
        for (uint8 i = index; i < next; i++) {
            assertFalse(bitmap.isSet(i));
        }
    }
}
