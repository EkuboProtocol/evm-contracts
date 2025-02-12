// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {SqrtRatio, toSqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO, ONE} from "../../src/types/sqrtRatio.sol";

contract SqrtRatioTypeTest is Test {
    function test_min_max_sqrt_ratio_isValid() public pure {
        assertTrue(MIN_SQRT_RATIO.isValid(), "min");
        assertTrue(MAX_SQRT_RATIO.isValid(), "max");
    }

    function test_outside_min_max_sqrt_ratio_isValid_false() public pure {
        assertFalse(SqrtRatio.wrap(SqrtRatio.unwrap(MIN_SQRT_RATIO) - 1).isValid(), "lt min");
        assertFalse(SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) + 1).isValid(), "gt max");
    }

    function test_toSqrtRatio_below_range_invalid(SqrtRatio sqrtRatio) public pure {
        sqrtRatio = SqrtRatio.wrap(uint96(bound(SqrtRatio.unwrap(sqrtRatio), 0, SqrtRatio.unwrap(MIN_SQRT_RATIO) - 1)));

        assertFalse(sqrtRatio.isValid());
    }

    function test_toSqrtRatio_above_range_invalid(SqrtRatio sqrtRatio) public pure {
        sqrtRatio = SqrtRatio.wrap(
            uint96(bound(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MAX_SQRT_RATIO) + 1, type(uint96).max))
        );

        assertFalse(sqrtRatio.isValid());
    }

    function test_toSqrtRatio_valid(uint256 sqrtRatioFixed) public pure {
        sqrtRatioFixed = bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());

        assertTrue(toSqrtRatio(sqrtRatioFixed, false).isValid(), "sqrt ratio rounded down is valid");
        assertTrue(toSqrtRatio(sqrtRatioFixed, true).isValid(), "sqrt ratio rounded up is valid");
    }

    function check_toFixed_toSqrtRatio(SqrtRatio sqrtRatio) public pure {
        // the assertions only hold true for valid sqrt ratios
        vm.assume(sqrtRatio.isValid());

        // whether you round up or down, it doesnt matter, since it started as a sqrt ratio we lose no precision
        assertEq(
            SqrtRatio.unwrap(toSqrtRatio(sqrtRatio.toFixed(), false)), SqrtRatio.unwrap(sqrtRatio), "rounding down"
        );
        assertEq(SqrtRatio.unwrap(toSqrtRatio(sqrtRatio.toFixed(), true)), SqrtRatio.unwrap(sqrtRatio), "rounding up");
    }

    function test_toFixed_toSqrtRatio_examples() public pure {
        assertEq(SqrtRatio.wrap(0x3ffffffffffffffff9ba1f6d).toFixed(), 79228162514264337593122979252);
        assertEq(SqrtRatio.unwrap(toSqrtRatio(79228162514264337593122979252, true)), 0x3ffffffffffffffff9ba1f6d);
    }

    function test_toSqrtRatio_examples() public pure {
        assertEq(SqrtRatio.unwrap(toSqrtRatio(1 << 128, false)), SqrtRatio.unwrap(ONE));
        assertEq(SqrtRatio.unwrap(toSqrtRatio(1 << 128, true)), SqrtRatio.unwrap(ONE));

        assertEq(toSqrtRatio(type(uint128).max, true).toFixed(), 1 << 128, "rounded up == ONE");
        assertEq(
            toSqrtRatio(type(uint128).max, false).toFixed(),
            340282366920938463463374607414588342272,
            "rounded down != ONE"
        );
    }

    function check_lt(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a < b, a.toFixed() < b.toFixed());
    }

    function check_le(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a <= b, a.toFixed() <= b.toFixed());
    }

    function check_gt(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a > b, a.toFixed() > b.toFixed());
    }

    function check_ge(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a >= b, a.toFixed() >= b.toFixed());
    }

    function check_eq(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a == b, a.toFixed() == b.toFixed());
    }

    function check_neq(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        assertEq(a != b, a.toFixed() != b.toFixed());
    }

    function check_max(SqrtRatio a, SqrtRatio b) public pure {
        SqrtRatio m = a.max(b);
        assertTrue(m == a || m == b);
        assertTrue(m >= a);
        assertTrue(m >= b);
    }

    function check_min(SqrtRatio a, SqrtRatio b) public pure {
        SqrtRatio m = a.min(b);
        assertTrue(m == a || m == b);
        assertTrue(m <= a);
        assertTrue(m <= b);
    }
}
