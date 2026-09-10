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
/// Bisection takes at most 127 iterations, independent of pool ticks/history.
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
        uint128 lo;
        while (lo < hi) {
            uint128 mid = lo + (hi - lo) / 2;
            (SqrtRatio price, uint128 a0, uint128 a1) = preview(market, token1, mid);
            if (excessToken0(price, a0, a1) != token1) lo = mid + 1;
            else hi = mid;
        }
        amount = _bestNeighbor(market, token1, lo);
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
