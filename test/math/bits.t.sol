// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {msb, MsbNonZero} from "../../src/math/bits.sol";

contract BitsTest is Test {
    function test_msb_zero() public {
        vm.expectRevert(MsbNonZero.selector);
        msb(0);
    }

    function test_msb_cases() public pure {
        assertEq(msb(1), 0);
        assertEq(msb(2), 1);
        assertEq(msb(3), 1);
        assertEq(msb(4), 2);
        assertEq(msb(type(uint128).max), 127);
    }

    function test_msb_fuzz_gt(uint256 x) public pure {
        vm.assume(x != 0);
        uint8 v = msb(x);
        assertGe(x, 1 << v);
    }

    function test_msb_boundaries(uint8 y) public pure {
        assertEq(msb(1 << y), y);
    }

    function test_msb_boundaries_plus_one(uint8 y) public pure {
        vm.assume(y != 0);
        assertEq(msb((1 << y) + 1), y);
    }

    function test_msb_boundaries_minus_one(uint8 y) public pure {
        vm.assume(y != 0);
        assertEq(msb((1 << y) - 1), y - 1);
    }

    function test_msb_fuzz_lt(uint256 x) public pure {
        vm.assume(x != 0);
        uint8 v = msb(x);
        vm.assume(v != type(uint8).max);
        assertLt(x, 1 << (v + 1));
    }
}
