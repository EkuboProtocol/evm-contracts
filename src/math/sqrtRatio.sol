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
    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount0();
    }

    unchecked {
        uint256 liquidityX128 = uint256(liquidity) << 128;
        uint256 amountAbs = FixedPointMathLib.abs(int256(amount));

        bool priceIncreasing = amount < 0;
        // If amountAbs > type(uint256).max / sqrtRatio => overflow in multiplication
        // sqrtRatio is never zero
        // We know if this overflows, the denominator computed below will also always overflow
        if (amountAbs > type(uint256).max / sqrtRatio) {
            // Overflow => return the min/max for the type
            return priceIncreasing ? type(uint256).max : 0;
        }

        uint256 product = amountAbs * sqrtRatio;

        // If amount < 0 => price is going up => denominator = (liquidityX128 - product)
        // If amount > 0 => price is going down => denominator = (liquidityX128 + product)
        if (priceIncreasing) {
            // “Removing token0” => denominator = liquidityX128 - product
            // Check underflow or zero denominator
            // If product >= liquidityX128 => underflow (or denominator=0)
            if (product >= liquidityX128) {
                return type(uint256).max;
            }
            uint256 denominator = liquidityX128 - product;

            sqrtRatioNext = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);
        } else {
            uint256 denominator = liquidityX128 + product;
            // If denominator addition overflowed...
            if (denominator < liquidityX128) {
                return 0;
            }

            sqrtRatioNext = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);
        }
    }

    return sqrtRatioNext;
}

error ZeroLiquidityNextSqrtRatioFromAmount1();

function nextSqrtRatioFromAmount1(uint256 sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (uint256 sqrtRatioNext)
{
    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount1();
    }

    unchecked {
        uint256 shiftedAmountAbs = FixedPointMathLib.abs(int256(amount)) << 128;

        bool priceDecreasing = amount < 0;

        (uint256 quotient, uint256 remainder) = (shiftedAmountAbs / liquidity, shiftedAmountAbs % liquidity);

        if (priceDecreasing) {
            if (quotient > sqrtRatio) {
                // Underflow => return 0
                return 0;
            }

            sqrtRatioNext = sqrtRatio - quotient;

            // If remainder is non-zero, we do one more step down (rounding).
            // If sqrtRatioNext == 0 => can't go lower => return 0
            if (remainder != 0) {
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

    return sqrtRatioNext;
}
