// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {msb, lsb, MsbNonZero, LsbNonZero} from "../../src/math/bits.sol";

contract BitsTest is Test {
    function test_msb_zero() public {
        vm.expectRevert(MsbNonZero.selector);
        msb(0);
    }

    function test_lsb_zero() public {
        vm.expectRevert(LsbNonZero.selector);
        lsb(0);
    }

    function test_msb_gas() public {
        vm.startSnapshotGas("msb(1)");
        assertEq(msb(1), 0);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("msb(type(uint128).max)");
        assertEq(msb(type(uint128).max), 127);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("msb(type(uint256).max)");
        assertEq(msb(type(uint256).max), 255);
        vm.stopSnapshotGas();
    }

    function test_lsb_gas() public {
        vm.startSnapshotGas("lsb(1)");
        assertEq(lsb(1), 0);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("lsb(type(uint128).max)");
        assertEq(lsb(type(uint128).max), 0);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("lsb(type(uint256).max)");
        assertEq(lsb(type(uint256).max), 0);
        vm.stopSnapshotGas();
    }

    function test_msb_cases() public pure {
        assertEq(msb(1), 0);
        assertEq(msb(2), 1);
        assertEq(msb(3), 1);
        assertEq(msb(4), 2);
        assertEq(msb(type(uint128).max), 127);
    }

    function test_lsb_cases() public pure {
        assertEq(lsb(1), 0);
        assertEq(lsb(2), 1);
        assertEq(lsb(3), 0);
        assertEq(lsb(4), 2);
        assertEq(lsb(1 << 128), 128);
    }

    function test_msb_fuzz_is_set(uint256 x) public pure {
        vm.assume(x != 0);
        uint8 v = msb(x);
        assertEq((1 << v) & x, (1 << v));
    }

    function test_msb_fuzz_gt(uint256 x) public pure {
        vm.assume(x != 0);
        uint8 v = msb(x);
        assertGe(x, 1 << v);
    }

    function test_lsb_fuzz_is_set(uint256 x) public pure {
        vm.assume(x != 0);
        uint8 v = lsb(x);
        assertEq(x & (1 << v), (1 << v));
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
