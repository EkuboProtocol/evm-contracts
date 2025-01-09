// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    sqrtRatioToTick,
    tickToSqrtRatio,
    MIN_TICK,
    MAX_TICK,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    TickMagnitude
} from "../../src/math/ticks.sol";

contract TicksTest is Test {
    function test_sqrtRatioToTick_one() public pure {
        assertEq(tickToSqrtRatio(0), 1 << 128);
    }

    function test_sqrtRatioToTick_max() public pure {
        assertEq(tickToSqrtRatio(MAX_TICK), MAX_SQRT_RATIO);
    }

    function test_sqrtRatioToTick_min() public pure {
        assertEq(tickToSqrtRatio(MIN_TICK), MIN_SQRT_RATIO);
    }

    function test_sqrtRatioToTick_reverts_magnitude() public {
        vm.expectRevert(TickMagnitude.selector);
        tickToSqrtRatio(MAX_TICK + 1);
    }

    function test_sqrtRatioToTick_reverts_magnitude_negative() public {
        vm.expectRevert(TickMagnitude.selector);
        tickToSqrtRatio(MIN_TICK - 1);
    }
}
