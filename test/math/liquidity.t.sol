// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    liquidityDeltaToAmountDelta,
    addLiquidityDelta,
    LiquidityUnderflow,
    LiquidityOverflow
} from "../../src/math/liquidity.sol";

import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, tickToSqrtRatio} from "../../src/math/ticks.sol";

int32 constant TICKS_IN_ONE_PERCENT = 9950;

// we need this for vm.assumeNoRevert to work
contract TestTarget {
    function amountDeltas(uint256 sqrtRatio, int128 liquidityDelta, uint256 sqrtRatioLower, uint256 sqrtRatioUpper)
        external
        pure
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = liquidityDeltaToAmountDelta(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);
    }
}

contract LiquidityTest is Test {
    TestTarget tt;

    function setUp() public {
        tt = new TestTarget();
    }

    function test_liquidityDeltaToAmountDelta_full_range_mid_price() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            0x100000000000000000000000000000000, // (1 << 128)
            10000,
            MIN_SQRT_RATIO,
            MAX_SQRT_RATIO
        );
        assertEq(amount0, 10000, "amount0");
        assertEq(amount1, 10000, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_sign(
        uint256 sqrtRatio,
        int128 liquidityDelta,
        uint256 sqrtRatioLower,
        uint256 sqrtRatioUpper
    ) public view {
        sqrtRatio = bound(sqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        sqrtRatioLower = bound(sqrtRatioLower, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        sqrtRatioUpper = bound(sqrtRatioUpper, MIN_SQRT_RATIO, MAX_SQRT_RATIO);

        vm.assumeNoRevert();
        (int128 delta0, int128 delta1) = tt.amountDeltas(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

        if (sqrtRatioLower == sqrtRatioUpper || liquidityDelta == 0) {
            assertEq(delta0, 0);
            assertEq(delta1, 0);
        } else if (liquidityDelta < 0) {
            assertLe(delta0, 0);
            assertLe(delta1, 0);
        } else if (liquidityDelta > 0) {
            assertTrue(delta1 != 0 || delta0 != 0);
            assertGe(delta0, 0);
            assertGe(delta1, 0);
        }
    }

    function test_liquidityDeltaToAmountDelta_full_range_mid_price_withdraw() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(0x100000000000000000000000000000000, -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, -9999, "amount0");
        assertEq(amount1, -9999, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_low_price_in_range() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            79228162514264337593543950336, // (1 << 96)
            10000,
            MIN_SQRT_RATIO,
            MAX_SQRT_RATIO
        );
        assertEq(amount0, 42949672960000, "amount0");
        assertEq(amount1, 1, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_low_price_in_range_withdraw() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(79228162514264337593543950336, -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, -42949672959999, "amount0");
        assertEq(amount1, 0, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_high_price_in_range() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(1 << 160, 10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, 1, "amount0");
        assertEq(amount1, 42949672960000, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_mid_price() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            1 << 128,
            10000,
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100 * -1),
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
        );
        assertEq(amount0, 3920, "amount0");
        assertEq(amount1, 3920, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_low() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            1 << 96, 10000, tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100), tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
        );
        assertEq(amount0, 10366, "amount0");
        assertEq(amount1, 0, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_high() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            1 << 160, 10000, tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100), tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
        );
        assertEq(amount0, 0, "amount0");
        assertEq(amount1, 10366, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_in_range() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(tickToSqrtRatio(0), 1000000000, tickToSqrtRatio(-10), tickToSqrtRatio(10));
        assertEq(amount0, 5000, "amount0");
        assertEq(amount1, 5000, "amount1");
    }

    function test_addLiquidityDelta() public {
        vm.expectRevert(LiquidityOverflow.selector);
        addLiquidityDelta(type(uint128).max, 1);
        vm.expectRevert(LiquidityUnderflow.selector);
        addLiquidityDelta(0, -1);
    }

    function test_addLiquidityDeltaInvariants(uint128 liquidity, int128 delta) public {
        int256 result = int256(uint256(liquidity)) + delta;
        if (result < 0) {
            vm.expectRevert(LiquidityUnderflow.selector);
        } else if (result > int256(uint256(type(uint128).max))) {
            vm.expectRevert(LiquidityOverflow.selector);
        }
        addLiquidityDelta(liquidity, delta);
    }

    function test_addLiquidityDelta_examples() public pure {
        assertEq(addLiquidityDelta(0, 100), 100);
        assertEq(addLiquidityDelta(0, type(int128).max), uint128(type(int128).max));
        assertEq(addLiquidityDelta(type(uint128).max, 0), type(uint128).max);
        assertEq(addLiquidityDelta(type(uint128).max >> 1, 1), uint128(1) << 127);
        assertEq(addLiquidityDelta(1 << 127, type(int128).min), 0);
        assertEq(addLiquidityDelta(0, type(int128).max), type(uint128).max >> 1);
        assertEq(addLiquidityDelta(type(uint128).max, type(int128).min), type(uint128).max >> 1);
    }
}
