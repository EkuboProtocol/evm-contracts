// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {CleanedUint128, wordUint128, castCleanedUint128} from "../types/cleaned.sol";

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

function amount0Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, CleanedUint128 liquidity, bool roundUp)
    pure
    returns (CleanedUint128 amount0)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

        if (roundUp) {
            uint256 result0 = FixedPointMathLib.fullMulDivUp(
                (liquidity.wordUint128() << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = FixedPointMathLib.divUp(result0, sqrtRatioLower);
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            assembly ("memory-safe") {
                amount0 := result
            }
        } else {
            uint256 result0 = FixedPointMathLib.fullMulDiv(
                (liquidity.wordUint128() << 128), (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper
            );
            uint256 result = result0 / sqrtRatioLower;
            if (result > type(uint128).max) revert Amount0DeltaOverflow();
            assembly ("memory-safe") {
                amount0 := result
            }
        }
    }
}

function amount1Delta(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, CleanedUint128 liquidity, bool roundUp)
    pure
    returns (CleanedUint128 amount1)
{
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

        uint256 difference = sqrtRatioUpper - sqrtRatioLower;

        if (roundUp) {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidity.wordUint128(), 128);
            uint256 liquidityWord = liquidity.wordUint128();
            assembly ("memory-safe") {
                // addition is safe from overflow because the result of fullMulDivN will never equal type(uint256).max
                result :=
                    add(result, iszero(iszero(mulmod(difference, liquidityWord, 0x100000000000000000000000000000000))))
            }
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            assembly ("memory-safe") {
                amount1 := result
            }
        } else {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidity.wordUint128(), 128);
            if (result > type(uint128).max) revert Amount1DeltaOverflow();
            assembly ("memory-safe") {
                amount1 := result
            }
        }
    }
}
