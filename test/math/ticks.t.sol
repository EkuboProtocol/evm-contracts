// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {sqrtRatioToTick, tickToSqrtRatio, InvalidTick, toSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, ONE} from "../../src/types/sqrtRatio.sol";

contract TicksTest is Test {
    function boundTick(int32 tick) internal pure returns (int32) {
        return int32(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK)));
    }

    function test_tickToSqrtRatio_one() public pure {
        assertEq(tickToSqrtRatio(0).toFixed(), (1 << 128));
    }

    function ttsr(int32 tick) external pure returns (SqrtRatio) {
        return tickToSqrtRatio(tick);
    }

    /// forge-config: default.isolate = true
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
        assertEq(MAX_SQRT_RATIO.toFixed(), 6276949602062853172742588666607187473671941430179807625216);
    }

    function test_tickToSqrtRatio_min() public pure {
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(MIN_TICK)), SqrtRatio.unwrap(MIN_SQRT_RATIO));
        assertEq(MIN_SQRT_RATIO.toFixed(), 18447191164202170524);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_tickToSqrtRatio_reverts_gt_max_tick(int32 tick) public {
        tick = int32(bound(tick, MAX_TICK + 1, type(int32).max));
        vm.expectRevert(abi.encodeWithSelector(InvalidTick.selector, tick));
        tickToSqrtRatio(tick);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_tickToSqrtRatio_reverts_lt_min_tick(int32 tick) public {
        tick = int32(bound(tick, type(int32).min, MIN_TICK - 1));
        vm.expectRevert(abi.encodeWithSelector(InvalidTick.selector, tick));
        tickToSqrtRatio(tick);
    }

    function test_tickToSqrtRatio_example() public pure {
        assertEq(tickToSqrtRatio(-18129342).toFixed(), 39364507096818414277565152436944896);
    }

    function test_sqrtRatioToTick_min_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(MIN_SQRT_RATIO), MIN_TICK);
    }

    function test_sqrtRatioToTick_max_sqrt_ratio() public pure {
        assertEq(sqrtRatioToTick(SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1)), MAX_TICK - 1);
    }

    function srtt(SqrtRatio sqrtRatio) external pure returns (int32) {
        return sqrtRatioToTick(sqrtRatio);
    }

    /// forge-config: default.isolate = true
    function test_sqrtRatioToTick_gas() public {
        this.srtt(ONE);
        vm.snapshotGasLastCall("sqrtRatioToTick(1)");

        this.srtt(MIN_SQRT_RATIO);
        vm.snapshotGasLastCall("sqrtRatioToTick(MIN_SQRT_RATIO)");

        this.srtt(SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1));
        vm.snapshotGasLastCall("sqrtRatioToTick(MAX_SQRT_RATIO)");

        // 1.01
        this.srtt(toSqrtRatio(ONE.toFixed() * 101 / 100, false));
        vm.snapshotGasLastCall("sqrtRatioToTick(1.01)");

        // 0.99
        this.srtt(toSqrtRatio(ONE.toFixed() * 99 / 100, false));
        vm.snapshotGasLastCall("sqrtRatioToTick(0.99)");
    }

    // these should be checked by halmos but they take a long time to run

    function test_check_tickToSqrtRatio_always_increasing(int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick < MAX_TICK);

        assertLt(SqrtRatio.unwrap(tickToSqrtRatio(tick)), SqrtRatio.unwrap(tickToSqrtRatio(tick + 1)));
    }

    function test_check_tickToSqrtRatio_inverse_sqrtRatioToTick_plus_one(int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick < MAX_TICK);

        SqrtRatio sqrtRatio = SqrtRatio.wrap(SqrtRatio.unwrap(tickToSqrtRatio(tick)) + 1);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_check_tickToSqrtRatio_always_valid(int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);

        assertTrue(tickToSqrtRatio(tick).isValid());
    }

    function test_check_tickToSqrtRatio_inverse_sqrtRatioToTick(int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);

        SqrtRatio sqrtRatio = tickToSqrtRatio(tick);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick);
    }

    function test_check_tickToSqrtRatio_inverse_sqrtRatioToTick_minus_one(int32 tick) public pure {
        vm.assume(tick > MIN_TICK && tick <= MAX_TICK);

        SqrtRatio sqrtRatio = toSqrtRatio(tickToSqrtRatio(tick).toFixed() - 1, false);
        int32 tickCalculated = sqrtRatioToTick(sqrtRatio);
        assertEq(tickCalculated, tick - 1);
    }

    function test_check_sqrtRatioToTick_within_bounds_lower(uint256 _sqrtRatio) public pure {
        _sqrtRatio = bound(_sqrtRatio, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());
        SqrtRatio sqrtRatio = toSqrtRatio(_sqrtRatio, false);

        int32 tick = sqrtRatioToTick(sqrtRatio);
        assertTrue(sqrtRatio >= tickToSqrtRatio(tick), "sqrt ratio gte tick to sqrt ratio");
    }

    function test_check_sqrtRatioToTick_within_bounds_upper(uint256 _sqrtRatio) public pure {
        _sqrtRatio = bound(_sqrtRatio, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());
        SqrtRatio sqrtRatio = toSqrtRatio(_sqrtRatio, false);

        int32 tick = sqrtRatioToTick(sqrtRatio);
        if (tick == MAX_TICK) {
            assertEq(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MAX_SQRT_RATIO));
        } else {
            assertTrue(sqrtRatio < tickToSqrtRatio(tick + 1), "sqrt ratio lt next tick sqrt ratio");
        }
    }

    // to run this test, update foundry.toml to uncomment the gas_limit, memory_limit lines and remove the skip_ prefix
    function skip_test_all_tick_values() public pure {
        uint256 fmp;

        assembly ("memory-safe") {
            fmp := mload(0x40)
        }

        SqrtRatio sqrtRatioLast;
        for (int32 i = MIN_TICK; i <= MAX_TICK; i++) {
            // price is always increasing
            SqrtRatio sqrtRatio = tickToSqrtRatio(i);
            assertTrue(sqrtRatio > sqrtRatioLast);
            sqrtRatioLast = sqrtRatio;

            if (i != MAX_TICK) test_check_tickToSqrtRatio_inverse_sqrtRatioToTick_plus_one(i);
            if (i != MIN_TICK) test_check_tickToSqrtRatio_inverse_sqrtRatioToTick_minus_one(i);

            assembly ("memory-safe") {
                mstore(0x40, fmp)
            }
        }
    }
}
