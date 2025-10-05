// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    liquidityDeltaToAmountDelta,
    LiquidityDeltaOverflow,
    addLiquidityDelta,
    maxLiquidity
} from "../../src/math/liquidity.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, ONE, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {PoolConfig, createPoolConfig} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

int32 constant TICKS_IN_ONE_PERCENT = 9950;

contract LiquidityTest is Test {
    function amountDeltas(
        SqrtRatio sqrtRatio,
        int128 liquidityDelta,
        SqrtRatio sqrtRatioLower,
        SqrtRatio sqrtRatioUpper
    ) external pure returns (int128 delta0, int128 delta1) {
        (delta0, delta1) = liquidityDeltaToAmountDelta(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);
    }

    function test_liquidityDeltaToAmountDelta_full_range_mid_price() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            ONE, // (1 << 128)
            10000,
            MIN_SQRT_RATIO,
            MAX_SQRT_RATIO
        );
        assertEq(amount0, 10000, "amount0");
        assertEq(amount1, 10000, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_sign(
        uint256 sqrtRatioFixed,
        int128 liquidityDelta,
        uint256 sqrtRatioLowerFixed,
        uint256 sqrtRatioUpperFixed
    ) public view {
        SqrtRatio sqrtRatio =
            toSqrtRatio(bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioLower =
            toSqrtRatio(bound(sqrtRatioLowerFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioUpper =
            toSqrtRatio(bound(sqrtRatioUpperFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);

        vm.assumeNoRevert();
        (int128 delta0, int128 delta1) = this.amountDeltas(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

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
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(ONE, -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, -9999, "amount0");
        assertEq(amount1, -9999, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_low_price_in_range() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(toSqrtRatio(1 << 96, false), 10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, 42949672960000, "amount0");
        assertEq(amount1, 1, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_low_price_in_range_withdraw() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(toSqrtRatio(1 << 96, false), -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, -42949672959999, "amount0");
        assertEq(amount1, 0, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_high_price_in_range() public pure {
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(toSqrtRatio(1 << 160, false), 10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        assertEq(amount0, 1, "amount0");
        assertEq(amount1, 42949672960000, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_mid_price() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            ONE, 10000, tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100 * -1), tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
        );
        assertEq(amount0, 3920, "amount0");
        assertEq(amount1, 3920, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_low() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            toSqrtRatio(1 << 96, false),
            10000,
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100),
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
        );
        assertEq(amount0, 10366, "amount0");
        assertEq(amount1, 0, "amount1");
    }

    function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_high() public pure {
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            toSqrtRatio(1 << 160, false),
            10000,
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100),
            tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
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

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addLiquidityDelta() public {
        vm.expectRevert(LiquidityDeltaOverflow.selector);
        addLiquidityDelta(type(uint128).max, 1);
        vm.expectRevert(LiquidityDeltaOverflow.selector);
        addLiquidityDelta(0, -1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addLiquidityDeltaInvariants(uint128 liquidity, int128 delta) public {
        int256 result = int256(uint256(liquidity)) + delta;
        if (result < 0) {
            vm.expectRevert(LiquidityDeltaOverflow.selector);
        } else if (result > int256(uint256(type(uint128).max))) {
            vm.expectRevert(LiquidityDeltaOverflow.selector);
        }
        assertEq(int256(uint256(addLiquidityDelta(liquidity, delta))), result);
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

    function ml(SqrtRatio sqrtRatio, SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 amount0, uint128 amount1)
        external
        pure
        returns (uint128)
    {
        return maxLiquidity(sqrtRatio, sqrtRatioA, sqrtRatioB, amount0, amount1);
    }

    function test_maxLiquidity(
        uint256 sqrtRatioFixed,
        uint256 sqrtRatioLowerFixed,
        uint256 sqrtRatioUpperFixed,
        uint128 amount0,
        uint128 amount1
    ) public view {
        amount0 = uint128(bound(amount0, 0, type(uint8).max));
        amount1 = uint128(bound(amount1, 0, type(uint8).max));
        // creates a minimum separation of .0001%, which causes it to overflow liquidity less often
        SqrtRatio sqrtRatio =
            toSqrtRatio(bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioLower =
            toSqrtRatio(bound(sqrtRatioLowerFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed() - 1), false);
        SqrtRatio sqrtRatioUpper =
            toSqrtRatio(bound(sqrtRatioUpperFixed, sqrtRatioLower.toFixed() + 1, MAX_SQRT_RATIO.toFixed()), false);

        // this can overflow in some cases
        vm.assumeNoRevert();
        uint128 liquidity = this.ml(sqrtRatio, sqrtRatioLower, sqrtRatioUpper, amount0, amount1);

        if (sqrtRatio <= sqrtRatioLower && amount0 == 0) {
            assertEq(liquidity, 0);
        } else if (sqrtRatio >= sqrtRatioUpper && amount1 == 0) {
            assertEq(liquidity, 0);
        }

        // if we were capped at max liquidity, there isn't much we can assert, except maybe that the amount deltas likely overflow
        if (liquidity <= uint128(type(int128).max)) {
            (int128 a, int128 b) = this.amountDeltas(sqrtRatio, int128(liquidity), sqrtRatioLower, sqrtRatioUpper);

            assertGe(a, 0);
            assertGe(b, 0);
            assertLe(uint128(a), amount0);
            assertLe(uint128(b), amount1);
        }
    }

    function test_maxLiquidityPerTick_at_min_price_tickSpacing1_overflows() public {
        // For tick spacing 1, calculate max liquidity per tick
        PoolConfig config = createPoolConfig({_fee: 0, _tickSpacing: 1, _extension: address(0)});
        uint128 maxLiquidityPerTick = config.maxLiquidityPerTick();

        // IMPORTANT: At extreme prices (near MIN_TICK), attempting to calculate the token amounts
        // for maxLiquidityPerTick causes overflow. This demonstrates that while maxLiquidityPerTick
        // is the theoretical maximum, in practice you cannot deposit that much liquidity at extreme
        // prices because the required token amounts exceed int128.max.

        // This test documents that overflow occurs at low prices
        int32 lowTick = MIN_TICK + 1000;

        // Expect Amount0DeltaOverflow when trying to calculate amounts for max liquidity
        // Use the external wrapper to make vm.expectRevert work
        vm.expectRevert();
        this.amountDeltas(
            tickToSqrtRatio(lowTick),
            int128(maxLiquidityPerTick),
            tickToSqrtRatio(lowTick),
            tickToSqrtRatio(lowTick + 1)
        );
    }

    function test_maxLiquidityPerTick_at_max_price_tickSpacing1_overflows() public {
        // For tick spacing 1, calculate max liquidity per tick
        PoolConfig config = createPoolConfig({_fee: 0, _tickSpacing: 1, _extension: address(0)});
        uint128 maxLiquidityPerTick = config.maxLiquidityPerTick();

        // IMPORTANT: At extreme prices (near MAX_TICK), attempting to calculate the token amounts
        // for maxLiquidityPerTick causes overflow. This demonstrates that while maxLiquidityPerTick
        // is the theoretical maximum, in practice you cannot deposit that much liquidity at extreme
        // prices because the required token amounts exceed int128.max.

        // This test documents that overflow occurs at high prices
        int32 highTick = MAX_TICK - 1000;

        // Expect Amount1DeltaOverflow when trying to calculate amounts for max liquidity
        // Use the external wrapper to make vm.expectRevert work
        vm.expectRevert();
        this.amountDeltas(
            tickToSqrtRatio(highTick),
            int128(maxLiquidityPerTick),
            tickToSqrtRatio(highTick - 1),
            tickToSqrtRatio(highTick)
        );
    }

    function test_maxLiquidityPerTick_at_mid_price_tickSpacing1() public pure {
        // For tick spacing 1, calculate max liquidity per tick
        PoolConfig config = createPoolConfig({_fee: 0, _tickSpacing: 1, _extension: address(0)});
        uint128 maxLiquidityPerTick = config.maxLiquidityPerTick();

        // At mid price (tick 0), liquidity is split between both tokens
        // Calculate the token amounts needed for max liquidity on a single tick
        (int128 amount0, int128 amount1) =
            liquidityDeltaToAmountDelta(ONE, int128(maxLiquidityPerTick), tickToSqrtRatio(-1), tickToSqrtRatio(1));

        // Assert the exact amounts for tick spacing 1 at mid price
        assertEq(amount0, 958_834_638_770_483_234_182_726, "amount0 at mid price");
        assertEq(amount1, 958_834_638_770_578_824_244_093, "amount1 at mid price");
    }
}
