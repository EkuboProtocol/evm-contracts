// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {computeFee, amountBeforeFee, AmountBeforeFeeOverflow} from "../../src/math/fee.sol";

contract FeeTest is Test {
    function test_computeFee() public pure {
        assertEq(computeFee(100, type(uint16).max), 100);
        assertEq(computeFee(100, 1 << 15), 50);
        assertEq(computeFee(100, 1 << 14), 25);
        assertEq(computeFee(100, 1 << 13), 13);
        assertEq(computeFee(type(uint128).max, type(uint16).max), 340277174624079928635746076935438991360);
    }

    function test_computeFee_always_le_amount(uint128 amount, uint16 fee) public pure {
        assertLe(computeFee(amount, fee), amount);
    }

    function abf(uint128 afterFee, uint16 fee) external pure returns (uint128 result) {
        result = amountBeforeFee(afterFee, fee);
    }

    function test_amountBeforeFee_computeFee(uint128 amount, uint16 fee) public view {
        vm.assumeNoRevert();

        uint128 before = this.abf(amount, fee);
        assertGe(before, amount);

        uint128 aft = before - computeFee(before, fee);
        assertEq(aft, amount);
    }

    function test_amountBeforeFee_examples() public pure {
        assertEq(amountBeforeFee(1, 1 << 15), 2);
        assertEq(amountBeforeFee(2, 1 << 14), 3);
        assertEq(amountBeforeFee(type(uint128).max, 0), type(uint128).max);
    }

    function test_amountBeforeFee_reference(uint128 amount, uint16 fee) public {
        uint256 numerator = uint256(amount) << 16;
        uint256 denominator = 65536 - uint256(fee);
        uint256 expected = numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
        if (expected > type(uint128).max) {
            vm.expectRevert(AmountBeforeFeeOverflow.selector);
            this.abf(amount, fee);
        } else {
            assertEq(this.abf(amount, fee), expected);
        }
    }

    function test_amountBeforeFee_overflowBoundary(uint16 fee) public {
        uint128 largest = uint128((uint256(type(uint128).max) * (65536 - uint256(fee))) >> 16);
        this.abf(largest, fee);
        assertEq(amountBeforeFee(0, fee), 0);
        if (fee != 0) {
            vm.expectRevert(AmountBeforeFeeOverflow.selector);
            this.abf(largest + 1, fee);
        }
    }
}
