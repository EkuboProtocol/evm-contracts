// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// EKU-648 found that _bestNeighbor's unconditional `result = crossing - 1` could choose a nonzero swap that
// does not beat the no-swap baseline. A nonzero amount makes _balance collect fees and execute a fee-paying
// swap, so "chosen > 0 && capacity(chosen) <= baseline" is a wasted swap. EKU-657 fixed it; these pin it.

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LaunchLiquidityMath} from "../../src/math/launchLiquidity.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract LaunchLiquidityBestNeighborTest is Test {
    function _capacity(LaunchLiquidityMath.Market memory m, bool token1, uint128 amount)
        private
        pure
        returns (uint128)
    {
        (SqrtRatio price, uint128 a0, uint128 a1) = LaunchLiquidityMath.preview(m, token1, amount);
        return LaunchLiquidityMath.liquidityFor(price, a0, a1);
    }

    function _check(LaunchLiquidityMath.Market memory m) private pure returns (bool wasted, uint128 amount) {
        bool token1;
        (token1, amount) = LaunchLiquidityMath.optimalSwap(m);
        uint128 baseline = LaunchLiquidityMath.liquidityFor(m.price, m.amount0, m.amount1);
        uint128 chosen = _capacity(m, token1, amount);
        require(chosen >= baseline, "chosen below baseline");
        wasted = amount != 0 && chosen <= baseline;
    }

    /// Small, brute-forceable markets (same domain as the PR's brute-force test).
    function testFuzz_eku648_noWastedSwapSmall(uint128 a0, uint128 a1, uint128 liquidity, uint64 fee, int32 tick)
        public
        pure
    {
        a0 = uint128(bound(a0, 0, 100));
        a1 = uint128(bound(a1, 0, 100));
        liquidity = uint128(bound(liquidity, 100, 100_000));
        fee = uint64(bound(fee, 0, uint64(uint256(1 << 64) / 10)));
        tick = int32(bound(tick, -100_000, 100_000));
        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
            tickToSqrtRatio(tick), MIN_SQRT_RATIO, MAX_SQRT_RATIO, liquidity, fee, a0, a1, liquidity / 2
        );
        (bool wasted,) = _check(m);
        assertFalse(wasted, "nonzero swap without capacity gain");
    }

    /// Realistic magnitudes, narrow and full bounds, near-balanced reserves (where crossing is small).
    function testFuzz_eku648_noWastedSwapRealistic(
        uint128 base,
        uint64 imbalancePpb,
        bool excess1,
        uint128 liquidity,
        uint64 fee,
        int32 tick,
        bool narrow,
        uint8 ownShare
    ) public pure {
        base = uint128(bound(base, 1e6, 1e30));
        imbalancePpb = uint64(bound(imbalancePpb, 0, 1e7)); // up to 1%
        liquidity = uint128(bound(liquidity, 1e6, 1e30));
        fee = uint64(bound(fee, 0, uint64(uint256(1 << 64) / 10)));
        tick = int32(bound(tick, -20_000_000, 20_000_000));
        SqrtRatio p = tickToSqrtRatio(tick);
        // balanced pair for `base` liquidity at p, then perturb one side
        uint128 a0 = uint128(uint256(base) * (1 << 128) / p.toFixed());
        uint128 a1 = uint128(uint256(base) * p.toFixed() >> 128);
        if (a0 == 0 || a1 == 0) return;
        if (excess1) a1 += uint128(uint256(a1) * imbalancePpb / 1e9);
        else a0 += uint128(uint256(a0) * imbalancePpb / 1e9);
        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
            p,
            narrow ? tickToSqrtRatio(tick - 2000) : MIN_SQRT_RATIO,
            narrow ? tickToSqrtRatio(tick + 2000) : MAX_SQRT_RATIO,
            liquidity,
            fee,
            a0,
            a1,
            uint128(uint256(liquidity) * ownShare / 255)
        );
        (bool wasted, uint128 amount) = _check(m);
        if (wasted) console2.log("wasted swap amount", amount);
        assertFalse(wasted, "nonzero swap without capacity gain");
    }

    /// Same domain, but bounds the size of any wasted swap: it must be dust (<= 16 raw units).
    function testFuzz_eku648_wastedSwapIsDust(
        uint128 base,
        uint64 imbalancePpb,
        bool excess1,
        uint128 liquidity,
        uint64 fee,
        int32 tick,
        bool narrow,
        uint8 ownShare
    ) public pure {
        base = uint128(bound(base, 1e6, 1e30));
        imbalancePpb = uint64(bound(imbalancePpb, 0, 1e9)); // up to 100%
        liquidity = uint128(bound(liquidity, 1e6, 1e30));
        fee = uint64(bound(fee, 0, uint64(uint256(1 << 64) / 10)));
        tick = int32(bound(tick, -20_000_000, 20_000_000));
        SqrtRatio p = tickToSqrtRatio(tick);
        uint128 a0 = uint128(uint256(base) * (1 << 128) / p.toFixed());
        uint128 a1 = uint128(uint256(base) * p.toFixed() >> 128);
        if (a0 == 0 || a1 == 0) return;
        if (excess1) a1 += uint128(uint256(a1) * imbalancePpb / 1e9);
        else a0 += uint128(uint256(a0) * imbalancePpb / 1e9);
        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
            p,
            narrow ? tickToSqrtRatio(tick - 2000) : MIN_SQRT_RATIO,
            narrow ? tickToSqrtRatio(tick + 2000) : MAX_SQRT_RATIO,
            liquidity,
            fee,
            a0,
            a1,
            uint128(uint256(liquidity) * ownShare / 255)
        );
        (bool wasted,) = _check(m);
        if (!wasted) return;
        (bool token1, uint128 amount) = LaunchLiquidityMath.optimalSwap(m);
        (, uint128 b0, uint128 b1) = LaunchLiquidityMath.preview(m, token1, amount);
        uint256 before = _value(m.price, a0, a1);
        uint256 afterSwap = _value(m.price, b0, b1);
        uint256 loss = before > afterSwap ? before - afterSwap : 0;
        // Wasted swaps come from quantization: input too small to move the compact sqrt ratio is booked
        // entirely as LP fees, and outputs round down by whole raw units. Bound the loss by dust: 16 raw
        // units of each token (valued at the price) + L/2^48 + value/2^40.
        uint256 unit0 = _value(m.price, 1, 0) + 1;
        assertLe(
            loss, 16 * (unit0 + 1) + (uint256(liquidity) >> 48) + (before >> 40), "wasted swap above quantization dust"
        );
    }

    function _value(SqrtRatio price, uint256 a0, uint256 a1) private pure returns (uint256) {
        uint256 s = price.toFixed();
        return FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(a0, s, 1 << 128), s, 1 << 128) + a1;
    }

    /// Exhaustive sweep over a small grid; reports the count and the largest wasted amount.
    function test_eku648_wastedSwapSweep() public pure {
        uint256 cases;
        uint256 wastedCount;
        uint128 maxWasted;
        uint128 maxWastedA0;
        uint128 maxWastedA1;
        for (uint128 a0 = 0; a0 <= 60; a0 += 3) {
            for (uint128 a1 = 0; a1 <= 60; a1 += 3) {
                for (uint256 li; li < 4; li++) {
                    uint128 liquidity = [uint128(100), 1_000, 10_000, 100_000][li];
                    for (uint256 ti; ti < 3; ti++) {
                        int32 tick = [int32(-50_000), 0, 50_000][ti];
                        LaunchLiquidityMath.Market memory m = LaunchLiquidityMath.Market(
                            tickToSqrtRatio(tick),
                            MIN_SQRT_RATIO,
                            MAX_SQRT_RATIO,
                            liquidity,
                            uint64(uint256(1 << 64) / 100),
                            a0,
                            a1,
                            liquidity / 2
                        );
                        (bool wasted, uint128 amount) = _check(m);
                        cases++;
                        if (wasted) {
                            wastedCount++;
                            if (amount > maxWasted) {
                                maxWasted = amount;
                                maxWastedA0 = a0;
                                maxWastedA1 = a1;
                            }
                        }
                    }
                }
            }
        }
        console2.log("grid cases", cases);
        console2.log("wasted nonzero swaps", wastedCount);
        console2.log("largest wasted input (raw units)", maxWasted);
        console2.log("  at a0", maxWastedA0);
        console2.log("  at a1", maxWastedA1);
        assertEq(wastedCount, 0, "wasted swaps");
    }
}
