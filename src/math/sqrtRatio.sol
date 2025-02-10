// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";

error ZeroLiquidityNextSqrtRatioFromAmount0();

// Compute the next ratio from a delta amount0, always rounded towards starting price for input, and
// away from starting price for output
function nextSqrtRatioFromAmount0(SqrtRatio _sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (SqrtRatio sqrtRatioNext)
{
    if (amount == 0) {
        return _sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount0();
    }

    uint256 sqrtRatio = _sqrtRatio.toFixed();

    uint256 liquidityX128 = uint256(liquidity) << 128;
    uint256 amountAbs = FixedPointMathLib.abs(int256(amount));

    if (amount < 0) {
        unchecked {
            // multiplication will revert on overflow, so we return the maximum value for the type
            if (amountAbs > type(uint256).max / sqrtRatio) {
                return SqrtRatio.wrap(type(uint128).max);
            }

            uint256 product = sqrtRatio * amountAbs;

            // again it will overflow if this is the case, so return the max value
            if (product >= liquidityX128) {
                return SqrtRatio.wrap(type(uint128).max);
            }

            uint256 denominator = liquidityX128 - product;

            sqrtRatioNext = toSqrtRatio(FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator), true);
        }
    } else {
        uint256 denominator;
        unchecked {
            uint256 denominatorP1 = liquidityX128 / sqrtRatio;

            // this can never overflow, amountAbs is limited to 2**128-1 and liquidityX128 / sqrtRatio is limited to (2**128-1 << 128)
            // adding the 2 values can at most equal type(uint256).max
            denominator = denominatorP1 + amountAbs;
        }

        sqrtRatioNext = toSqrtRatio(FixedPointMathLib.divUp(liquidityX128, denominator), true);
    }
}

error ZeroLiquidityNextSqrtRatioFromAmount1();

function nextSqrtRatioFromAmount1(SqrtRatio _sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (SqrtRatio sqrtRatioNext)
{
    if (amount == 0) {
        return _sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount1();
    }

    uint256 sqrtRatio = _sqrtRatio.toFixed();

    unchecked {
        uint256 shiftedAmountAbs = FixedPointMathLib.abs(int256(amount)) << 128;

        uint256 quotient = shiftedAmountAbs / liquidity;

        if (amount < 0) {
            if (quotient > sqrtRatio) {
                // Underflow => return 0
                return SqrtRatio.wrap(0);
            }

            uint256 sqrtRatioNextFixed = sqrtRatio - quotient;

            // If remainder is non-zero, we do one more step down (rounding).
            // If sqrtRatioNext == 0 => can't go lower => return 0
            if ((shiftedAmountAbs % liquidity) != 0) {
                if (sqrtRatioNextFixed == 0) {
                    return SqrtRatio.wrap(0);
                }
                sqrtRatioNextFixed -= 1;
            }

            sqrtRatioNext = toSqrtRatio(sqrtRatioNextFixed, false);
        } else {
            uint256 sum = sqrtRatio + quotient;
            if (sum < sqrtRatio || sum > type(uint192).max) {
                return SqrtRatio.wrap(type(uint128).max);
            }
            sqrtRatioNext = toSqrtRatio(sum, false);
        }
    }
}
