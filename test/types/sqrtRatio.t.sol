// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    SqrtRatio,
    toSqrtRatio,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    MIN_SQRT_RATIO_RAW,
    MAX_SQRT_RATIO_RAW,
    TWO_POW_95,
    TWO_POW_94,
    TWO_POW_62,
    TWO_POW_62_MINUS_ONE,
    BIT_MASK,
    ONE,
    MAX_FIXED_VALUE_ROUND_UP,
    ValueOverflowsSqrtRatioContainer
} from "../../src/types/sqrtRatio.sol";

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

    /// @dev The range check as it was written before it became a single subtract-and-compare, kept
    ///   verbatim as the oracle for the differential tests below.
    function twoSidedIsValid(SqrtRatio sqrtRatio) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(
                // greater than or equal to TWO_POW_62, i.e. the whole number portion is nonzero
                gt(and(sqrtRatio, not(BIT_MASK)), TWO_POW_62_MINUS_ONE),
                // and between min/max sqrt ratio
                and(iszero(lt(sqrtRatio, MIN_SQRT_RATIO_RAW)), iszero(gt(sqrtRatio, MAX_SQRT_RATIO_RAW)))
            )
        }
    }

    /// @dev Builds the value in assembly so that any bits above 96 reach the predicate uncleaned.
    function rawSqrtRatio(uint256 raw) internal pure returns (SqrtRatio sqrtRatio) {
        assembly ("memory-safe") {
            sqrtRatio := raw
        }
    }

    function assertMatchesTwoSided(uint256 raw) internal pure {
        SqrtRatio sqrtRatio = rawSqrtRatio(raw);
        assertEq(sqrtRatio.isValid(), twoSidedIsValid(sqrtRatio), vm.toString(raw));
    }

    function boundaryValues() internal pure returns (uint256[29] memory values) {
        uint256 min = MIN_SQRT_RATIO_RAW;
        uint256 max = MAX_SQRT_RATIO_RAW;
        values = [
            uint256(0),
            1,
            TWO_POW_62_MINUS_ONE,
            TWO_POW_62,
            min - 1,
            min,
            min + 1,
            uint256(TWO_POW_94) - 1,
            TWO_POW_94,
            uint256(TWO_POW_94) + TWO_POW_62_MINUS_ONE,
            uint256(TWO_POW_94) + TWO_POW_62,
            uint256(TWO_POW_95) - 1,
            TWO_POW_95,
            uint256(TWO_POW_95) + TWO_POW_62_MINUS_ONE,
            uint256(TWO_POW_95) + TWO_POW_62,
            uint256(BIT_MASK) - 1,
            BIT_MASK,
            uint256(BIT_MASK) + TWO_POW_62_MINUS_ONE,
            uint256(BIT_MASK) + TWO_POW_62,
            max - 1,
            max,
            max + 1,
            type(uint96).max,
            uint256(type(uint96).max) + 1,
            SqrtRatio.unwrap(ONE),
            // words whose difference from the minimum wraps around, or lands next to the accepted width
            type(uint256).max,
            type(uint256).max - (max - min),
            min - 1 + (uint256(1) << 255),
            max - min
        ];
    }

    function test_isValid_matches_two_sided_check_at_boundaries() public pure {
        uint256[29] memory values = boundaryValues();
        for (uint256 i; i < values.length; i++) {
            uint256 value = values[i];
            assertMatchesTwoSided(value);
            // the same boundary with dirty bits above the 96 bit container
            assertMatchesTwoSided(value | (uint256(1) << 96));
            assertMatchesTwoSided(value | (uint256(1) << 255));
            assertMatchesTwoSided(value | (type(uint256).max << 96));
        }
    }

    function test_isValid_at_boundaries() public pure {
        uint256 min = MIN_SQRT_RATIO_RAW;
        uint256 max = MAX_SQRT_RATIO_RAW;

        assertTrue(rawSqrtRatio(min).isValid(), "min");
        assertTrue(rawSqrtRatio(max).isValid(), "max");
        assertTrue(ONE.isValid(), "one");
        assertFalse(rawSqrtRatio(0).isValid(), "zero");
        assertFalse(rawSqrtRatio(min - 1).isValid(), "min - 1");
        assertFalse(rawSqrtRatio(max + 1).isValid(), "max + 1");
        assertFalse(rawSqrtRatio(type(uint96).max).isValid(), "uint96 max");

        // in range, but the mantissa is below 2**62 in each of the upper three regions
        assertFalse(rawSqrtRatio(uint256(TWO_POW_94) + TWO_POW_62_MINUS_ONE).isValid(), "01 region");
        assertTrue(rawSqrtRatio(uint256(TWO_POW_94) + TWO_POW_62).isValid(), "01 region normalized");
        assertFalse(rawSqrtRatio(uint256(TWO_POW_95) + TWO_POW_62_MINUS_ONE).isValid(), "10 region");
        assertTrue(rawSqrtRatio(uint256(TWO_POW_95) + TWO_POW_62).isValid(), "10 region normalized");
        assertFalse(rawSqrtRatio(uint256(BIT_MASK) + TWO_POW_62_MINUS_ONE).isValid(), "11 region");
        assertTrue(rawSqrtRatio(uint256(BIT_MASK) + TWO_POW_62).isValid(), "11 region normalized");

        // a value below the minimum must not wrap into range
        assertFalse(rawSqrtRatio(min - 1 + (uint256(1) << 255)).isValid(), "dirty below min");
        assertFalse(rawSqrtRatio(type(uint256).max).isValid(), "all bits");
        // valid values with dirty upper bits are rejected rather than truncated
        assertFalse(rawSqrtRatio(min | (uint256(1) << 96)).isValid(), "dirty min");
        assertFalse(rawSqrtRatio(max | (uint256(1) << 255)).isValid(), "dirty max");
    }

    function test_isValid_matches_two_sided_check(uint256 raw, uint8 shape, uint256 offset) public pure {
        uint256[29] memory values = boundaryValues();
        shape %= 4;
        unchecked {
            if (shape == 1) {
                // any value that fits the container
                raw = uint96(raw);
            } else if (shape == 2) {
                // within 32 of a boundary, on either side, wrapping around zero
                raw = values[offset % values.length] + (raw % 65) - 32;
            } else if (shape == 3) {
                // within 32 of a boundary, with dirty upper bits
                raw = (values[offset % values.length] + (raw % 65) - 32) | (offset << 96);
            }
        }
        assertMatchesTwoSided(raw);
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

    function check_toSqrtRatio_always_valid(uint256 sqrtRatioFixed, bool roundUp) public pure {
        sqrtRatioFixed = bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());
        SqrtRatio sqrtRatio = toSqrtRatio(sqrtRatioFixed, roundUp);
        assertTrue(sqrtRatio.isValid());
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

        assertEq(
            toSqrtRatio(MAX_FIXED_VALUE_ROUND_UP, true).toFixed(),
            6277101735386680763835789422890753766045298094089858711552,
            "rounded down != ONE"
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_toSqrtRatio_fails_if_greater_than_MAX_FIXED_VALUE_ROUND_UP() public {
        vm.expectRevert(ValueOverflowsSqrtRatioContainer.selector);
        toSqrtRatio(MAX_FIXED_VALUE_ROUND_UP + 1, true);
    }

    function test_toSqrtRatio_succeeds_if_greater_than_MAX_FIXED_VALUE_ROUND_UP_DOWN() public pure {
        assertEq(
            toSqrtRatio(MAX_FIXED_VALUE_ROUND_UP + 1, false).toFixed(),
            6277101735386680763835789422890753766045298094089858711552
        );
    }

    function test_toSqrtRatio_succeeds_uint192_max_round_down() public pure {
        assertEq(
            toSqrtRatio(uint256(type(uint192).max), false).toFixed(),
            6277101735386680763835789422890753766045298094089858711552
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_toSqrtRatio_fails_if_greater_than_uint192_max_round_down() public {
        vm.expectRevert(ValueOverflowsSqrtRatioContainer.selector);
        toSqrtRatio(uint256(type(uint192).max) + 1, false);
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
