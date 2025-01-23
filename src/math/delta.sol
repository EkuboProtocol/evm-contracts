// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error ZeroSqrtRatio();

error Amount0DeltaOverflow();
error Amount1DeltaOverflow();

function sortSqrtRatios(uint256 sqrtRatioA, uint256 sqrtRatioB)
    pure
    returns (uint256 sqrtRatioLower, uint256 sqrtRatioUpper)
{
    (sqrtRatioLower, sqrtRatioUpper) =
        (FixedPointMathLib.min(sqrtRatioA, sqrtRatioB), FixedPointMathLib.max(sqrtRatioA, sqrtRatioB));
    if (sqrtRatioLower == 0) revert ZeroSqrtRatio();
}

function amount0Delta(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount0)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

        if (roundUp) {
            uint256 result0 = FixedPointMathLib.fullMulDivUp(
                (uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = FixedPointMathLib.divUp(result0, sqrtRatioLower);
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        } else {
            uint256 result0 = FixedPointMathLib.fullMulDiv(
                (uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = result0 / sqrtRatioLower;
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        }
    }
}

function amount1Delta(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount1)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

        uint256 difference = sqrtRatioUpper - sqrtRatioLower;

        if (roundUp) {
            uint256 result = FixedPointMathLib.fullMulDivUp(difference, liquidity, 1 << 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        } else {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidity, 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        }
    }
}
