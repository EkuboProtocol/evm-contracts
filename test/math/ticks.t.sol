// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {sqrtRatioToTick, tickToSqrtRatio, InvalidTick, toSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";

contract TicksTest is Test {
    function boundTick(int32 tick) internal pure returns (int32) {
        return int32(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK)));
    }

    function test_tickToSqrtRatio_one() public pure {
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(0)), 0x80000000000000008000000000000000);
    }

    function ttsr(int32 tick) external pure returns (SqrtRatio) {
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
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(MAX_TICK)), SqrtRatio.unwrap(MAX_SQRT_RATIO));
    }

    function test_tickToSqrtRatio_min() public pure {
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(MIN_TICK)), SqrtRatio.unwrap(MIN_SQRT_RATIO));
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
        assertLt(SqrtRatio.unwrap(tickToSqrtRatio(tick)), SqrtRatio.unwrap(tickToSqrtRatio(tick + 1)));
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick(int32 tick) public pure {
        tick = boundTick(tick);
        SqrtRatio sqrtRatio = tickToSqrtRatio(tick);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_tickToSqrtRatio_example() public pure {
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(-18129342)), 19682253548409207138782582852285036);
    }

    function test_sqrtRatioToTick_min_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(MIN_SQRT_RATIO), MIN_TICK);
    }

    function test_sqrtRatioToTick_max_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1)), MAX_TICK - 1);
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick_plus_one(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick < MAX_TICK);
        SqrtRatio sqrtRatio = SqrtRatio.wrap(SqrtRatio.unwrap(tickToSqrtRatio(tick)) + 1);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_tickToSqrtRatio_inverse_sqrtRatioToTick_minus_one(int32 tick) public pure {
        tick = boundTick(tick);
        vm.assume(tick > MIN_TICK);

        SqrtRatio sqrtRatio = toSqrtRatio(tickToSqrtRatio(tick).toFixed() - 1, false);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick - 1);
    }

    function test_sqrtRatioToTick_within_bounds(SqrtRatio sqrtRatio) public pure {
        if (SqrtRatio.unwrap(sqrtRatio) >= (1 << 127)) {
            sqrtRatio = SqrtRatio.wrap(
                uint128(
                    bound(SqrtRatio.unwrap(sqrtRatio), ((1 << 127) + (1 << 63)), SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1)
                )
            );
        } else {
            sqrtRatio = SqrtRatio.wrap(
                uint128(bound(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MIN_SQRT_RATIO), (1 << 127) - 1))
            );
        }

        int32 tick = sqrtRatioToTick(sqrtRatio);
        assertGe(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(tickToSqrtRatio(tick)));
        assertLt(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(tickToSqrtRatio(tick + 1)));
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

    function srtt(SqrtRatio sqrtRatio) external pure returns (int32) {
        return sqrtRatioToTick(sqrtRatio);
    }

    function test_sqrtRatioToTick_gas() public {
        this.srtt(SqrtRatio.wrap((1 << 63) + (1 << 127)));
        vm.snapshotGasLastCall("sqrtRatioToTick(1 << 128)");

        this.srtt(MIN_SQRT_RATIO);
        vm.snapshotGasLastCall("sqrtRatioToTick(MIN_SQRT_RATIO)");

        this.srtt(SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1));
        vm.snapshotGasLastCall("sqrtRatioToTick(MAX_SQRT_RATIO)");
    }
}
