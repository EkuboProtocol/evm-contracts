// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

error Amount0DeltaOverflow();
error Amount1DeltaOverflow();

function sortAndConvertToFixedSqrtRatios(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB)
    pure
    returns (uint256 sqrtRatioLower, uint256 sqrtRatioUpper)
{
    sqrtRatioLower = sqrtRatioA.toFixed();
    sqrtRatioUpper = sqrtRatioB.toFixed();
    assembly ("memory-safe") {
        let diff := mul(sub(sqrtRatioLower, sqrtRatioUpper), gt(sqrtRatioLower, sqrtRatioUpper))

        sqrtRatioLower := sub(sqrtRatioLower, diff)
        sqrtRatioUpper := add(sqrtRatioUpper, diff)
    }
}

/// @dev Assumes that the sqrt ratios are valid
function amount0Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount0)
{
    (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);
    amount0 = amount0DeltaSorted(sqrtRatioLower, sqrtRatioUpper, liquidity, roundUp);
}

/// @dev Assumes that the sqrt ratios are non-zero and sorted
function amount0DeltaSorted(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount0)
{
    unchecked {
        if (roundUp) {
            uint256 result0 = FixedPointMathLib.fullMulDivUp(
                (uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = FixedPointMathLib.divUp(result0, sqrtRatioLower);
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        } else {
            uint256 result0 = FixedPointMathLib.fullMulDivUnchecked(
                (uint256(liquidity) << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = FixedPointMathLib.rawDiv(result0, sqrtRatioLower);
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            amount0 = uint128(result);
        }
    }
}

/// @dev Assumes that the sqrt ratios are valid
function amount1Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount1)
{
    (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);
    amount1 = amount1DeltaSorted(sqrtRatioLower, sqrtRatioUpper, liquidity, roundUp);
}

function amount1DeltaSorted(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount1)
{
    unchecked {
        uint256 difference = sqrtRatioUpper - sqrtRatioLower;

        if (roundUp) {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidity, 128);
            assembly {
                // addition is safe from overflow because the result of fullMulDivN will never equal type(uint256).max
                result :=
                    add(result, iszero(iszero(mulmod(difference, liquidity, 0x100000000000000000000000000000000))))
            }
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        } else {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidity, 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            amount1 = uint128(result);
        }
    }
}
