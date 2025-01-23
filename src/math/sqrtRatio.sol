// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error ZeroLiquidityNextSqrtRatioFromAmount0();

// Compute the next ratio from a delta amount0, always rounded towards starting price for input, and
// away from starting price for output
function nextSqrtRatioFromAmount0(uint256 sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (uint256 sqrtRatioNext)
{
    assert(sqrtRatio != 0);

    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount0();
    }

    uint256 liquidityX128 = uint256(liquidity) << 128;
    uint256 amountAbs = FixedPointMathLib.abs(int256(amount));

    if (amount < 0) {
        unchecked {
            // multiplication will revert on overflow, so we return the maximum value for the type
            if (amountAbs > type(uint256).max / sqrtRatio) {
                return type(uint256).max;
            }

            uint256 product = sqrtRatio * amountAbs;

            // again it will overflow if this is the case, so return the max value
            if (product >= liquidityX128) {
                return type(uint256).max;
            }

            uint256 denominator = liquidityX128 - product;

            sqrtRatioNext = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);
        }
    } else {
        uint256 denominator;
        unchecked {
            uint256 denominatorP1 = liquidityX128 / sqrtRatio;

            // this can never overflow, amountAbs is limited to 2**128-1 and liquidityX128 / sqrtRatio is limited to (2**128-1 << 128)
            // adding the 2 values can at most equal type(uint256).max
            denominator = denominatorP1 + amountAbs;
        }

        sqrtRatioNext = FixedPointMathLib.divUp(liquidityX128, denominator);
    }
}

error ZeroLiquidityNextSqrtRatioFromAmount1();

function nextSqrtRatioFromAmount1(uint256 sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (uint256 sqrtRatioNext)
{
    assert(sqrtRatio != 0);

    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount1();
    }

    unchecked {
        uint256 shiftedAmountAbs = FixedPointMathLib.abs(int256(amount)) << 128;

        uint256 quotient = shiftedAmountAbs / liquidity;

        if (amount < 0) {
            if (quotient > sqrtRatio) {
                // Underflow => return 0
                return 0;
            }

            sqrtRatioNext = sqrtRatio - quotient;

            // If remainder is non-zero, we do one more step down (rounding).
            // If sqrtRatioNext == 0 => can't go lower => return 0
            if ((shiftedAmountAbs % liquidity) != 0) {
                if (sqrtRatioNext == 0) {
                    return 0;
                }
                sqrtRatioNext -= 1;
            }
        } else {
            uint256 sum = sqrtRatio + quotient;
            if (sum < sqrtRatio) {
                return type(uint256).max;
            }
            sqrtRatioNext = sum;
        }
    }
}
