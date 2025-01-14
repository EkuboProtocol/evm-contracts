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

    function test_toggle_isSet(uint256 bitmap, uint8 index) public pure {
        assertEq(Bitmap.wrap(bitmap).isSet(index), !Bitmap.wrap(bitmap).toggle(index).isSet(index));
    }
}
