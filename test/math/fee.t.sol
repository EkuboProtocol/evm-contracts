// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";

contract FeeTest is Test {
    function test_computeFee() public pure {
        assertEq(computeFee(100, type(uint128).max), 100);
        assertEq(computeFee(100, 1 << 127), 50);
        assertEq(computeFee(100, 1 << 126), 25);
        assertEq(computeFee(100, 1 << 125), 13);
        assertEq(computeFee(type(uint128).max, type(uint128).max), type(uint128).max);
    }

    function test_computeFee_always_le_amount(uint128 amount, uint128 fee) public pure {
        assertLe(computeFee(amount, fee), amount);
    }

    function test_amountBeforeFee_computeFee(uint128 amount, uint128 fee) public pure {
        // prevents overflow
        amount = uint128(bound(amount, 0, type(uint128).max >> 1));
        fee = uint128(bound(fee, 0, 1 << 127));

        uint128 before = amountBeforeFee(amount, fee);
        uint128 aft = before - computeFee(before, fee);
        assertEq(aft, amount);
    }

    function test_amountBeforeFee_examples() public pure {
        assertEq(amountBeforeFee(1, 1 << 127), 2);
        assertEq(amountBeforeFee(2, 1 << 126), 3);
        assertEq(amountBeforeFee(type(uint128).max, 0), type(uint128).max);
    }
}
