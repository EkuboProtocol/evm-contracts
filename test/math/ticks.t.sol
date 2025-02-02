// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {sqrtRatioToTick, tickToSqrtRatio, InvalidTick, InvalidSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/constants.sol";

contract TicksTest is Test {
    function boundTick(int32 tick) internal pure returns (int32) {
        return int32(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK)));
    }

    function test_tickToSqrtRatio_one() public pure {
        assertEq(tickToSqrtRatio(0), 1 << 128);
    }

    function ttsr(int32 tick) external pure returns (uint256) {
        return tickToSqrtRatio(tick);
    }

    function test_tickToSqrtRatio_gas() public {
        this.ttsr(0);
        vm.snapshotGasLastCall("tickToSqrtRatio(0)");

        this.ttsr(MIN_TICK);
        vm.snapshotGasLastCall("tickToSqrtRatio(MIN_TICK)");

        this.ttsr(MAX_TICK);
        vm.snapshotGasLastCall("tickToSqrtRatio(MAX_TICK)");

        this.ttsr(-0x3ffffff);
        vm.snapshotGasLastCall("tickToSqrtRatio(-0x3ffffff)");

        this.ttsr(0x3ffffff);
        vm.snapshotGasLastCall("tickToSqrtRatio(0x3ffffff)");
    }

    function test_tickToSqrtRatio_max() public pure {
        assertEq(tickToSqrtRatio(MAX_TICK), MAX_SQRT_RATIO);
    }

    function test_tickToSqrtRatio_min() public pure {
        assertEq(tickToSqrtRatio(MIN_TICK), MIN_SQRT_RATIO);
    }

    function test_tickToSqrtRatio_reverts_gt_max_tick(int32 tick) public {
        tick = int32(bound(tick, MAX_TICK + 1, type(int32).max));
        vm.expectRevert(abi.encodeWithSelector(InvalidTick.selector, tick));
        tickToSqrtRatio(tick);
    }

    function test_tickToSqrtRatio_reverts_lt_min_tick(int32 tick) public {
        tick = int32(bound(tick, type(int32).min, MIN_TICK - 1));
        vm.expectRevert(abi.encodeWithSelector(InvalidTick.selector, tick));
        tickToSqrtRatio(tick);
    }

    function test_tickToSqrtRatio_always_increasing(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick != MAX_TICK);
        assertLt(tickToSqrtRatio(tick), tickToSqrtRatio(tick + 1));
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick(int32 tick) public pure {
        tick = boundTick(tick);
        uint256 sqrtRatio = tickToSqrtRatio(tick);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_tickToSqrtRatio_example() public pure {
        assertEq(tickToSqrtRatio(-18129342), 39364507096818414277565165704570072);
    }

    function test_sqrtRatioToTick_invalid_sqrtRatio_lt_min(uint256 sqrtRatio) public {
        sqrtRatio = bound(sqrtRatio, 0, MIN_SQRT_RATIO - 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidSqrtRatio.selector, sqrtRatio));
        sqrtRatioToTick(sqrtRatio);
    }

    function test_sqrtRatioToTick_invalid_sqrtRatio_ge_max(uint256 sqrtRatio) public {
        sqrtRatio = bound(sqrtRatio, MAX_SQRT_RATIO, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(InvalidSqrtRatio.selector, sqrtRatio));
        sqrtRatioToTick(sqrtRatio);
    }

    function test_sqrtRatioToTick_min_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(MIN_SQRT_RATIO), MIN_TICK);
    }

    function test_sqrtRatioToTick_max_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(MAX_SQRT_RATIO - 1), MAX_TICK - 1);
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

    function test_sqrtRatioToTick_within_bounds(uint256 sqrtRatio) public pure {
        sqrtRatio = bound(sqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO - 1);
        int32 tick = sqrtRatioToTick(sqrtRatio);
        assertGe(sqrtRatio, tickToSqrtRatio(tick));
        assertLt(sqrtRatio, tickToSqrtRatio(tick + 1));
    }

    // this takes about 1 hour to run
    function skip_test_all_tick_values() public pure {
        uint256 fmp;
        assembly ("memory-safe") {
            fmp := mload(0x40)
        }
        for (int32 i = MIN_TICK; i <= MAX_TICK; i++) {
            if (i != MAX_TICK) test_tickToSqrtRatio_inverse_sqrtRatioToTick_plus_one(i);
            if (i != MIN_TICK) test_tickToSqrtRatio_inverse_sqrtRatioToTick_minus_one(i);
            assembly ("memory-safe") {
                mstore(0x40, fmp)
            }
        }
    }

    function srtt(uint256 sqrtRatio) external pure returns (int32) {
        return sqrtRatioToTick(sqrtRatio);
    }

    function test_sqrtRatioToTick_gas() public {
        this.srtt(1 << 128);
        vm.snapshotGasLastCall("sqrtRatioToTick(1 << 128)");

        this.srtt(MIN_SQRT_RATIO);
        vm.snapshotGasLastCall("sqrtRatioToTick(MIN_SQRT_RATIO)");

        this.srtt(MAX_SQRT_RATIO - 1);
        vm.snapshotGasLastCall("sqrtRatioToTick(MAX_SQRT_RATIO)");
    }
}
