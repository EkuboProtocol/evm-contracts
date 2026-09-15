// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {LaunchLiquidityMath} from "../../src/math/launchLiquidity.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {maxLiquidity} from "../../src/math/liquidity.sol";

contract LaunchLiquidityMathTest is Test {
    function _capacity(LaunchLiquidityMath.Market memory m, bool token1, uint128 amount)
        private
        pure
        returns (uint128)
    {
        (SqrtRatio price, uint128 a0, uint128 a1) = LaunchLiquidityMath.preview(m, token1, amount);
        return LaunchLiquidityMath.liquidityFor(price, a0, a1);
    }

    function testFuzz_optimalAgainstBruteForce(uint128 a0, uint128 a1, uint128 liquidity, uint64 fee, int32 tick)
        public
    {
        a0 = uint128(bound(a0, 0, 100));
        a1 = uint128(bound(a1, 0, 100));
        liquidity = uint128(bound(liquidity, 100, 100_000));
        fee = uint64(bound(fee, 0, uint64(uint256(1 << 64) / 10)));
        tick = int32(bound(tick, -100_000, 100_000));
        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
            tickToSqrtRatio(tick), MIN_SQRT_RATIO, MAX_SQRT_RATIO, liquidity, fee, a0, a1, liquidity / 2
        );
        (bool token1, uint128 amount) = LaunchLiquidityMath.optimalSwap(m);
        uint128 chosen = _capacity(m, token1, amount);
        uint128 best;
        for (uint128 i = 0; i <= a0; i++) {
            uint128 candidate = _capacity(m, false, i);
            if (candidate > best) best = candidate;
        }
        for (uint128 i = 0; i <= a1; i++) {
            uint128 candidate = _capacity(m, true, i);
            if (candidate > best) best = candidate;
        }
        assertEq(chosen, best);
        assertGe(chosen, LaunchLiquidityMath.liquidityFor(m.price, a0, a1));
    }

    function testFuzz_emptyPoolPriceUsesBothBalances(uint128 a0, uint128 a1) public {
        a0 = uint128(bound(a0, 1e6, 1e30));
        a1 = uint128(bound(a1, 1e6, 1e30));
        SqrtRatio price = LaunchLiquidityMath.depositPrice(a0, a1);
        uint128 liquidity = LaunchLiquidityMath.liquidityFor(price, a0, a1);
        assertGt(liquidity, 0);
        assertEq(liquidity, maxLiquidity(price, MIN_SQRT_RATIO, MAX_SQRT_RATIO, a0, a1));
        assertGe(liquidity, LaunchLiquidityMath.liquidityFor(toSqrtRatio(price.toFixed() - 1, false), a0, a1));
        assertGe(liquidity, LaunchLiquidityMath.liquidityFor(toSqrtRatio(price.toFixed() + 1, true), a0, a1));
    }

    function testFuzz_extremeMarketNeverSpendsMoreThanInventory(
        uint128 a0,
        uint128 a1,
        uint128 liquidity,
        uint64 fee,
        int32 tick
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        tick = int32(bound(tick, -88700000, 88700000));
        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
            tickToSqrtRatio(tick),
            tickToSqrtRatio(tick - 1000),
            tickToSqrtRatio(tick + 1000),
            liquidity,
            fee,
            a0,
            a1,
            liquidity / 2
        );
        (bool token1, uint128 amount) = LaunchLiquidityMath.optimalSwap(m);
        assertLe(amount, token1 ? a1 : a0);
        (SqrtRatio price, uint128 after0, uint128 after1) = LaunchLiquidityMath.preview(m, token1, amount);
        assertTrue(price.isValid());
        assertTrue(price >= m.lower && price <= m.upper);
        assertGe(
            LaunchLiquidityMath.liquidityFor(price, after0, after1), LaunchLiquidityMath.liquidityFor(m.price, a0, a1)
        );
    }

    function test_compactEncodingBoundaries() public {
        SqrtRatio price = LaunchLiquidityMath.depositPrice(1 << 96, 1 << 32);
        assertTrue(price.isValid());
        price = LaunchLiquidityMath.depositPrice(1 << 32, 1 << 96);
        assertTrue(price.isValid());
        price = LaunchLiquidityMath.depositPrice(1 << 100, 1 << 100);
        assertTrue(price.isValid());
    }

    function test_extremeBudgetsNearEndpointsDoNotOverflow() public {
        SqrtRatio high = SqrtRatio.wrap(SqrtRatio.unwrap(MAX_SQRT_RATIO) - 1);
        SqrtRatio low = SqrtRatio.wrap(SqrtRatio.unwrap(MIN_SQRT_RATIO) + 1);
        assertGt(LaunchLiquidityMath.liquidityFor(high, type(uint128).max, type(uint128).max), 0);
        assertGt(LaunchLiquidityMath.liquidityFor(low, type(uint128).max, type(uint128).max), 0);
        LaunchLiquidityMath.depositPrice(type(uint128).max, 1);
        LaunchLiquidityMath.depositPrice(1, type(uint128).max);
    }
}
