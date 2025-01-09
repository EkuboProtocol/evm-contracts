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
}
