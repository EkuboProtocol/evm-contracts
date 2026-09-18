// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio} from "../types/sqrtRatio.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "./sqrtRatio.sol";
import {amount0Delta, amount1Delta} from "./delta.sol";
import {computeFee, amountBeforeFee} from "./fee.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @dev Full-range pools follow XYK in virtual reserves X=L/s, Y=L*s. Fees are
/// excluded from price-impacting input. Solve for equal deposit capacity on both
/// sides after that swap, using Core's rounding and finite full-range endpoints.
/// A closed-form root narrows an exact bisection over the same preview oracle,
/// independent of pool ticks/history.
library LaunchLiquidityMath {
    struct Market {
        SqrtRatio price;
        SqrtRatio lower;
        SqrtRatio upper;
        uint128 liquidity;
        uint64 fee;
        uint128 amount0;
        uint128 amount1;
        uint128 ownLiquidity;
    }

    /// @dev Coefficients above this abort the closed form; boundaries still apply.
    uint256 private constant _COEFF_LIM = 126;
    /// @dev Input reserves above this many bits are shifted down before solving.
    uint256 private constant _NORM_BITS = 100;

    function liquidityFor(SqrtRatio price, uint128 amount0, uint128 amount1) internal pure returns (uint128) {
        if (price <= MIN_SQRT_RATIO) return _capacity0(MIN_SQRT_RATIO, amount0);
        if (price >= MAX_SQRT_RATIO) return _capacity1(MAX_SQRT_RATIO, amount1);
        return uint128(FixedPointMathLib.min(_capacity0(price, amount0), _capacity1(price, amount1)));
    }

    function excessToken0(SqrtRatio price, uint128 amount0, uint128 amount1) internal pure returns (bool) {
        if (price <= MIN_SQRT_RATIO) return false;
        if (price >= MAX_SQRT_RATIO) return true;
        return _capacity0(price, amount0) > _capacity1(price, amount1);
    }

    function _capacity0(SqrtRatio price, uint128 amount) private pure returns (uint128) {
        uint256 lower = price.toFixed();
        uint256 upper = MAX_SQRT_RATIO.toFixed();
        uint256 numerator = FixedPointMathLib.fullMulDivN(lower, upper, 128);
        return _cappedMulDiv(amount, numerator, upper - lower);
    }

    function _capacity1(SqrtRatio price, uint128 amount) private pure returns (uint128) {
        return uint128(
            FixedPointMathLib.min(
                (uint256(amount) << 128) / (price.toFixed() - MIN_SQRT_RATIO.toFixed()), type(uint128).max
            )
        );
    }

    /// @dev Saturate at Core's liquidity capacity rather than overflowing for an
    /// asset-heavy portfolio very near a full-range endpoint.
    function _cappedMulDiv(uint256 a, uint256 b, uint256 denominator) private pure returns (uint128) {
        uint256 high;
        assembly ("memory-safe") {
            let low := mul(a, b)
            let mm := mulmod(a, b, not(0))
            high := sub(sub(mm, low), lt(mm, low))
        }
        if (high >= denominator) return type(uint128).max;
        return uint128(FixedPointMathLib.min(FixedPointMathLib.fullMulDiv(a, b, denominator), type(uint128).max));
    }

    /// @notice Finds the representable full-range deposit price for an empty pool.
    /// @dev Caller must supply both assets. Does not rely on an empty pool's current price.
    function depositPrice(uint128 amount0, uint128 amount1) internal pure returns (SqrtRatio) {
        // Search fixed-point values: compact SqrtRatio encodings contain invalid gaps.
        uint256 lo = MIN_SQRT_RATIO.toFixed();
        uint256 hi = MAX_SQRT_RATIO.toFixed();
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (excessToken0(toSqrtRatio(mid, false), amount0, amount1)) hi = mid;
            else lo = mid;
        }
        SqrtRatio lower = toSqrtRatio(lo, false);
        SqrtRatio upper = toSqrtRatio(hi, true);
        return liquidityFor(lower, amount0, amount1) >= liquidityFor(upper, amount0, amount1) ? lower : upper;
    }

    /// @notice Limits input such that output at the current price fits headroom.
    function inputLimit(SqrtRatio price, bool token1, uint128 headroom) internal pure returns (uint128) {
        uint256 numerator = token1 ? price.toFixed() : 1 << 128;
        uint256 denominator = token1 ? 1 << 128 : price.toFixed();
        uint256 limit = FixedPointMathLib.fullMulDiv(headroom, numerator, denominator);
        limit = FixedPointMathLib.fullMulDiv(limit, numerator, denominator);
        return uint128(FixedPointMathLib.min(limit, uint128(type(int128).max)));
    }

    function optimalSwap(Market memory market) internal pure returns (bool token1, uint128 amount) {
        token1 = !excessToken0(market.price, market.amount0, market.amount1);
        uint128 headroom = type(uint128).max - (token1 ? market.amount0 : market.amount1);
        headroom = uint128(FixedPointMathLib.min(headroom, uint128(type(int128).max)));
        uint128 hi = uint128(
            FixedPointMathLib.min(token1 ? market.amount1 : market.amount0, inputLimit(market.price, token1, headroom))
        );
        // The closed-form root bounds the balance flip from above, so searching
        // [0, hiS] is exact when the flip lands inside. Otherwise fall back to the
        // full range, which matches the original search bit-for-bit.
        uint256 seed = _swapRoot(market, token1, hi);
        uint128 hiS = seed == type(uint256).max ? hi : uint128(FixedPointMathLib.min(seed, uint256(hi)));
        uint128 cross = _bisect(market, token1, 0, hiS);
        if (hiS < hi && (hiS == 0 || cross == hiS)) cross = _bisect(market, token1, 0, hi);
        amount = _bestNeighbor(market, token1, cross);
    }

    /// @dev Lowest input with a flipped excess side, or the top edge when the flip
    /// lies beyond it. Identical to the original full-range search when hi is passed.
    function _bisect(Market memory market, bool token1, uint128 lo, uint128 hi) private pure returns (uint128) {
        while (lo < hi) {
            uint128 mid = lo + (hi - lo) / 2;
            (SqrtRatio price, uint128 a0, uint128 a1) = preview(market, token1, mid);
            if (excessToken0(price, a0, a1) != token1) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    function _bestNeighbor(Market memory market, bool token1, uint128 crossing) private pure returns (uint128) {
        uint128 best = liquidityFor(market.price, market.amount0, market.amount1);
        uint128 result;
        if (crossing != 0) {
            uint128 candidate = _capacityAfter(market, token1, crossing - 1);
            if (candidate > best) best = candidate;
            result = crossing - 1;
        }
        if (_capacityAfter(market, token1, crossing) > best) result = crossing;
        return result;
    }

    /// @dev Bit length of x, with bit length 0 for x == 0.
    function _bl(uint256 x) private pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := sub(256, clz(x))
        }
    }

    /// @dev x * y / 2**shift, supporting shift beyond 255. Caller must ensure the
    /// intermediate x * y / 2**min(shift, 240) fits in 256 bits.
    function _mulDivPow2(uint256 x, uint256 y, uint256 shift) private pure returns (uint256 r) {
        uint256 first = shift > 240 ? 240 : shift;
        r = FixedPointMathLib.fullMulDiv(x, y, 1 << first) >> (shift - first);
    }

    /// @dev Input-side view of the market: reserves, price, and normalization shift.
    /// Selling token1 is mirrored to the token0 case with the reciprocal price, which
    /// keeps the single quadratic below instead of a cubic.
    function _orient(Market memory market, bool token1)
        private
        pure
        returns (uint128 aIn, uint128 aOut, uint256 s, uint128 l, uint256 e)
    {
        l = market.liquidity;
        uint256 m = FixedPointMathLib.max(_bl(token1 ? market.amount1 : market.amount0), _bl(l));
        m = FixedPointMathLib.max(m, _bl(token1 ? market.amount0 : market.amount1));
        e = m > _NORM_BITS ? m - _NORM_BITS : 0;
        if (token1) {
            return (market.amount1 >> e, market.amount0 >> e, type(uint256).max / market.price.toFixed(), l >> e, e);
        }
        return (market.amount0 >> e, market.amount1 >> e, market.price.toFixed(), l >> e, e);
    }

    /// @dev Common scale-down shift t for the quadratic coefficients plus the split u
    /// for the two-step C evaluation, derived from operand bit length upper bounds.
    function _rootShifts(uint256 blIn, uint256 blOut, uint256 blL, uint256 blS, uint256 blD0)
        private
        pure
        returns (uint256 t, uint256 u)
    {
        int256 bIn = int256(blIn);
        int256 bOut = int256(blOut);
        int256 bL = int256(blL);
        int256 bS2 = int256(blS) * 2 - 128 + 1;
        int256 bAlpha = int256(blS);
        int256 bLs2 = bL + bS2 - 128 + 1;
        int256 bT1 = bOut + bAlpha - 128 + 1;
        int256 bT2 = bLs2 + 1;
        int256 bSum = (bT1 > bT2 ? bT1 : bT2) + 1;
        int256 reqA = bAlpha + bSum - 246;
        int256 reqB1 = 1 + bOut + bL + bAlpha - 128 - 117;
        int256 reqB2 = bL + bLs2 - 116;
        int256 bT0 = bIn + bS2 - 128 + 1;
        int256 bD0 = (bT0 > bOut ? bT0 : bOut) + 1;
        int256 reqC = bD0 + 2 * bL - 117;
        int256 m = reqA;
        m = reqB1 > m ? reqB1 : m;
        m = reqB2 > m ? reqB2 : m;
        m = reqC > m ? reqC : m;
        t = m > 0 ? uint256(m) : 0;
        int256 split = bD0 + bL + 1 - 200;
        if (split < 0) split = 0;
        u = split > int256(t) ? t : uint256(split);
    }

    /// @dev Closed-form swap input for equal deposit capacity. With s the input-side
    /// sqrt price, L pool liquidity, fee f, input reserve aIn and output reserve aOut,
    /// spending d (gross) with net n = d(1-f), price moves to s' = Ls/(L+ns) and
    /// output is L(s-s'). Full deposit needs aOut + L(s-s') = s'^2(aIn - rho*d),
    /// where rho = 1 - f*own/L recycles this position's fee share. Substituting d
    /// gives A*d^2 + B*d + C = 0 with A = a(aOut*a + Ls^2*b),
    /// B = 2*aOut*L*a + L^2*s^2*(b+r), C = -L^2*(aIn*s^2 - aOut),
    /// in units a = (1-f)s, b = 1-f. Returns the root clamped to hi, or
    /// type(uint256).max when no interior root exists or the scaled coefficients
    /// exceed the guard, in which case boundaries decide.
    function _swapRoot(Market memory market, bool token1, uint128 hi) private pure returns (uint256) {
        (uint128 aIn, uint128 aOut, uint256 s, uint128 l, uint256 e) = _orient(market, token1);
        uint256 beta = (1 << 64) - market.fee;
        uint256 alpha = FixedPointMathLib.fullMulDiv(beta, s, 1 << 64);
        uint256 s2 = FixedPointMathLib.fullMulDiv(s, s, 1 << 128);
        uint256 t0 = FixedPointMathLib.fullMulDiv(aIn, s2, 1 << 128);
        if (t0 <= aOut) return type(uint256).max;
        uint256 dm = t0 - aOut;
        uint256 rho =
            (1 << 128) - FixedPointMathLib.fullMulDiv(market.fee, market.ownLiquidity, market.liquidity) * (1 << 64);
        uint256 ls2 = FixedPointMathLib.fullMulDiv(l, s2, 1 << 128);
        (uint256 t, uint256 u) = _rootShifts(_bl(aIn), _bl(aOut), _bl(l), _bl(s), _bl(dm));
        uint256 aC = _mulDivPow2(
            alpha,
            FixedPointMathLib.fullMulDiv(aOut, alpha, 1 << 128) + FixedPointMathLib.fullMulDiv(ls2, beta, 1 << 64),
            128 + t
        );
        uint256 bC = _mulDivPow2(uint256(aOut) * l, 2 * alpha, 128 + t)
            + _mulDivPow2(_mulDivPow2(l, ls2, t), beta + (rho >> 64), 64);
        uint256 cC = _mulDivPow2(_mulDivPow2(dm, l, u), l, t - u);
        if (aC > (1 << _COEFF_LIM) || bC > (1 << _COEFF_LIM) || cC > (1 << _COEFF_LIM)) {
            return type(uint256).max;
        }
        uint256 disc = bC * bC + 4 * aC * cC;
        uint256 sq = FixedPointMathLib.sqrt(disc);
        if (aC == 0) return bC == 0 ? type(uint256).max : FixedPointMathLib.min(cC / bC, hi >> e) << e;
        uint256 denom = bC + sq;
        if (denom == 0) return 0;
        return FixedPointMathLib.min(FixedPointMathLib.fullMulDiv(2 * cC, 1, denom), hi >> e) << e;
    }

    function _capacityAfter(Market memory market, bool token1, uint128 amount) private pure returns (uint128) {
        (SqrtRatio price, uint128 a0, uint128 a1) = preview(market, token1, amount);
        return liquidityFor(price, a0, a1);
    }

    function preview(Market memory market, bool token1, uint128 amount)
        internal
        pure
        returns (SqrtRatio price, uint128 amount0, uint128 amount1)
    {
        int128 net = int128(amount - computeFee(amount, market.fee));
        price = token1
            ? nextSqrtRatioFromAmount1(market.price, market.liquidity, net)
            : nextSqrtRatioFromAmount0(market.price, market.liquidity, net);
        SqrtRatio limit = token1 ? market.upper : market.lower;
        if (token1 ? price > limit : price < limit) {
            price = limit;
            uint128 netUsed = token1
                ? amount1Delta(market.price, price, market.liquidity, true)
                : amount0Delta(market.price, price, market.liquidity, true);
            amount = amountBeforeFee(netUsed, market.fee);
            net = int128(netUsed);
        }
        uint128 output = token1
            ? amount0Delta(market.price, price, market.liquidity, false)
            : amount1Delta(market.price, price, market.liquidity, false);
        uint128 cost = amount - _rebate(market, price, amount, uint128(net));
        amount0 = token1 ? market.amount0 + output : market.amount0 - cost;
        amount1 = token1 ? market.amount1 - cost : market.amount1 + output;
    }

    /// @dev Match Core's two floors when recycling this position's share of internal fees.
    function _rebate(Market memory market, SqrtRatio price, uint128 gross, uint128 net) private pure returns (uint128) {
        uint128 fees = price == market.price ? gross : gross - net;
        uint256 feesPerLiquidity = (uint256(fees) << 128) / market.liquidity;
        return uint128(FixedPointMathLib.fullMulDivN(feesPerLiquidity, market.ownLiquidity, 128));
    }
}
