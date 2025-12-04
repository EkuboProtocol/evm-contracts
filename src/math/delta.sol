// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

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
        uint256 liquidityX128;
        assembly ("memory-safe") {
            liquidityX128 := shl(128, liquidity)
        }
        if (roundUp) {
            uint256 result0 =
                FixedPointMathLib.fullMulDivUp(liquidityX128, (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper);
            assembly ("memory-safe") {
                let result := add(div(result0, sqrtRatioLower), iszero(iszero(mod(result0, sqrtRatioLower))))
                if shr(128, result) {
                    // cast sig "Amount0DeltaOverflow()"
                    mstore(0, 0xb4ef2546)
                    revert(0x1c, 0x04)
                }
                amount0 := result
            }
        } else {
            uint256 result0 =
                FixedPointMathLib.fullMulDivUnchecked(liquidityX128, (sqrtRatioUpper - sqrtRatioLower), sqrtRatioUpper);
            uint256 result = FixedPointMathLib.rawDiv(result0, sqrtRatioLower);
            assembly ("memory-safe") {
                if shr(128, result) {
                    // cast sig "Amount0DeltaOverflow()"
                    mstore(0, 0xb4ef2546)
                    revert(0x1c, 0x04)
                }
                amount0 := result
            }
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
        uint256 liquidityU256;
        assembly ("memory-safe") {
            liquidityU256 := liquidity
        }

        if (roundUp) {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidityU256, 128);
            assembly ("memory-safe") {
                // addition is safe from overflow because the result of fullMulDivN will never equal type(uint256).max
                result := add(
                    result,
                    iszero(iszero(mulmod(difference, liquidityU256, 0x100000000000000000000000000000000)))
                )
                if shr(128, result) {
                    // cast sig "Amount1DeltaOverflow()"
                    mstore(0, 0x59d2b24a)
                    revert(0x1c, 0x04)
                }
                amount1 := result
            }
        } else {
            uint256 result = FixedPointMathLib.fullMulDivN(difference, liquidityU256, 128);
            assembly ("memory-safe") {
                if shr(128, result) {
                    // cast sig "Amount1DeltaOverflow()"
                    mstore(0, 0x59d2b24a)
                    revert(0x1c, 0x04)
                }
                amount1 := result
            }
        }
    }
}
