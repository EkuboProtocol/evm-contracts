// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio, toSqrtRatio, toSqrtRatioUp, MAX_FIXED_VALUE_ROUND_UP} from "../types/sqrtRatio.sol";

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
                return SqrtRatio.wrap(type(uint96).max);
            }

            uint256 product = sqrtRatio * amountAbs;

            // again it will overflow if this is the case, so return the max value
            if (product >= liquidityX128) {
                return SqrtRatio.wrap(type(uint96).max);
            }

            uint256 denominator = liquidityX128 - product;

            uint256 resultFixed = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);

            if (resultFixed > MAX_FIXED_VALUE_ROUND_UP) {
                return SqrtRatio.wrap(type(uint96).max);
            }

            sqrtRatioNext = toSqrtRatioUp(resultFixed);
        }
    } else {
        uint256 denominator;
        unchecked {
            uint256 denominatorP1 = liquidityX128 / sqrtRatio;

            // this can never overflow, amountAbs is limited to 2**128-1 and liquidityX128 / sqrtRatio is limited to (2**128-1 << 128)
            // adding the 2 values can at most equal type(uint256).max
            denominator = denominatorP1 + amountAbs;
        }

        sqrtRatioNext = toSqrtRatioUp(FixedPointMathLib.divUp(liquidityX128, denominator));
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
            if (quotient >= sqrtRatio) {
                // Underflow => return 0
                return SqrtRatio.wrap(0);
            }

            uint256 sqrtRatioNextFixed = sqrtRatio - quotient;

            assembly ("memory-safe") {
                // subtraction of 1 is safe because sqrtRatio > quotient => sqrtRatio - quotient >= 1
                sqrtRatioNextFixed := sub(sqrtRatioNextFixed, iszero(iszero(mod(shiftedAmountAbs, liquidity))))
            }

            sqrtRatioNext = toSqrtRatio(sqrtRatioNextFixed);
        } else {
            uint256 sum = sqrtRatio + quotient;
            if (sum < sqrtRatio || sum > type(uint192).max) {
                return SqrtRatio.wrap(type(uint96).max);
            }
            sqrtRatioNext = toSqrtRatio(sum);
        }
    }
}
