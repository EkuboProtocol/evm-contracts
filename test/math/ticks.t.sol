// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    log2,
    sqrtRatioToTick,
    tickToSqrtRatio,
    MIN_TICK,
    MAX_TICK,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    TickMagnitude
} from "../../src/math/ticks.sol";

contract TicksTest is Test {
    function boundTick(int32 tick) internal pure returns (int32) {
        return int32(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK)));
    }

    function test_tickToSqrtRatio_one() public pure {
        assertEq(tickToSqrtRatio(0), 1 << 128);
    }

    function test_tickToSqrtRatio_max() public pure {
        assertEq(tickToSqrtRatio(MAX_TICK), MAX_SQRT_RATIO);
    }

    function test_tickToSqrtRatio_min() public pure {
        assertEq(tickToSqrtRatio(MIN_TICK), MIN_SQRT_RATIO);
    }

    function test_tickToSqrtRatio_reverts_magnitude() public {
        vm.expectRevert(TickMagnitude.selector);
        tickToSqrtRatio(MAX_TICK + 1);
    }

    function test_tickToSqrtRatio_reverts_magnitude_negative() public {
        vm.expectRevert(TickMagnitude.selector);
        tickToSqrtRatio(MIN_TICK - 1);
    }

    function test_tickToSqrtRatio_always_increasing(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick != MAX_TICK);
        assertLt(tickToSqrtRatio(tick), tickToSqrtRatio(tick + 1));
    }

    function test_log2() public pure {
        assertEq(log2(1 << 128), 0);
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick(int32 tick) public pure {
        tick = boundTick(tick);
        uint256 sqrtRatio = tickToSqrtRatio(tick);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick_plus_one(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick < MAX_TICK);
        uint256 sqrtRatio = tickToSqrtRatio(tick) + 1;
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick_minus_one(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick > MIN_TICK);
        uint256 sqrtRatio = tickToSqrtRatio(tick) - 1;
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick - 1);
    }
}
