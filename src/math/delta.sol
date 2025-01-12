// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error ZeroSqrtRatio();

error Amount0DeltaOverflow();
error Amount1DeltaOverflow();

/**
 * @notice Computes the difference in amount of token0 between two sqrt ratios,
 *         rounding up if `roundUp = true`.
 * @dev Reverts if `sqrtRatioLower` is zero.
 *      Reverts if the final 256-bit intermediate calculations overflow a uint128.
 * @param sqrtRatioA The first sqrt price ratio as a Q128.128-like number
 * @param sqrtRatioB The second sqrt price ratio as a Q128.128-like number
 * @param liquidity  The amount of usable liquidity, stored as a uint128
 * @param roundUp    If true, the division is rounded up; otherwise truncated
 * @return amount0   The token0 delta amount as a uint128
 */
function amount0Delta(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount0)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) =
            sqrtRatioA < sqrtRatioB ? (sqrtRatioA, sqrtRatioB) : (sqrtRatioB, sqrtRatioA);

        if (sqrtRatioLower == 0) revert ZeroSqrtRatio();

        if (liquidity == 0 || sqrtRatioLower == sqrtRatioUpper) {
            return 0;
        }

        if (roundUp) {
            uint256 result0 = FixedPointMathLib.mulDivUp(
                (uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = FixedPointMathLib.divUp(result0, sqrtRatioLower);
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        } else {
            uint256 result0 =
                FixedPointMathLib.mulDiv((uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper);
            uint256 result = result0 / sqrtRatioLower;
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        }
    }
}

/**
 * @notice Computes the difference in amount of token1 between two sqrt ratios,
 *         rounding up if `roundUp = true`.
 * @dev Reverts if `sqrtRatioLower` is zero.
 *      Reverts if the multiplication of `(sqrtRatioUpper - sqrtRatioLower) * liquidity`
 *      overflows 256 bits.
 * @param sqrtRatioA The first sqrt price ratio as a Q128.128-like number
 * @param sqrtRatioB The second sqrt price ratio as a Q128.128-like number
 * @param liquidity  The amount of usable liquidity, stored as a uint128
 * @param roundUp    If true, the final result is incremented by 1 if there is a remainder
 * @return amount1   The token1 delta amount as a uint128
 */
function amount1Delta(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount1)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) =
            sqrtRatioA < sqrtRatioB ? (sqrtRatioA, sqrtRatioB) : (sqrtRatioB, sqrtRatioA);

        if (sqrtRatioLower == 0) revert ZeroSqrtRatio();

        if (liquidity == 0 || sqrtRatioLower == sqrtRatioUpper) {
            return 0;
        }

        uint256 difference = sqrtRatioUpper - sqrtRatioLower;

        if (roundUp) {
            uint256 result = FixedPointMathLib.mulDivUp(difference, liquidity, 1 << 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        } else {
            uint256 result = FixedPointMathLib.mulDiv(difference, liquidity, 1 << 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        }
    }
}
