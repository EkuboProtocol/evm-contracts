// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";

import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, tickToSqrtRatio} from "../../src/math/ticks.sol";

int32 constant TICKS_IN_ONE_PERCENT = 9950;

contract LiquidityTest is Test {
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
}
