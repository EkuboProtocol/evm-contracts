// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

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

function amount0Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount0)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

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

function amount1Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
    pure
    returns (uint128 amount1)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

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
