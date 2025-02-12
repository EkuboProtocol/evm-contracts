// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {amount0Delta, amount1Delta, sortSqrtRatios} from "./delta.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

/**
 * @notice Returns the token0 and token1 delta owed for a given change in liquidity.
 * @param sqrtRatio        Current price (as a sqrt ratio).
 * @param liquidityDelta   Signed liquidity change; positive = added, negative = removed.
 * @param sqrtRatioLower   The lower bound of the price range (as a sqrt ratio).
 * @param sqrtRatioUpper   The upper bound of the price range (as a sqrt ratio).
 */
function liquidityDeltaToAmountDelta(
    SqrtRatio sqrtRatio,
    int128 liquidityDelta,
    SqrtRatio sqrtRatioLower,
    SqrtRatio sqrtRatioUpper
) pure returns (int128 delta0, int128 delta1) {
    unchecked {
        if (liquidityDelta == 0) {
            return (0, 0);
        }
        bool isPositive = (liquidityDelta > 0);
        // type(uint256).max cast to int256 is -1
        int256 sign = int256(FixedPointMathLib.ternary(isPositive, 1, type(uint256).max));
        // absolute value of a int128 always fits in a uint128
        uint128 magnitude = uint128(FixedPointMathLib.abs(liquidityDelta));

        if (sqrtRatio <= sqrtRatioLower) {
            delta0 = SafeCastLib.toInt128(
                sign * int256(uint256(amount0Delta(sqrtRatioLower, sqrtRatioUpper, magnitude, isPositive)))
            );
        } else if (sqrtRatio < sqrtRatioUpper) {
            delta0 = SafeCastLib.toInt128(
                sign * int256(uint256(amount0Delta(sqrtRatio, sqrtRatioUpper, magnitude, isPositive)))
            );
            delta1 = SafeCastLib.toInt128(
                sign * int256(uint256(amount1Delta(sqrtRatioLower, sqrtRatio, magnitude, isPositive)))
            );
        } else {
            delta1 = SafeCastLib.toInt128(
                sign * int256(uint256(amount1Delta(sqrtRatioLower, sqrtRatioUpper, magnitude, isPositive)))
            );
        }
    }
}

function maxLiquidityForToken0(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 amount) pure returns (uint256) {
    unchecked {
        uint256 numerator_1 = FixedPointMathLib.fullMulDivN(sqrtRatioLower, sqrtRatioUpper, 128);

        return FixedPointMathLib.fullMulDiv(amount, numerator_1, (sqrtRatioUpper - sqrtRatioLower));
    }
}

function maxLiquidityForToken1(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 amount) pure returns (uint256) {
    unchecked {
        return (uint256(amount) << 128) / (sqrtRatioUpper - sqrtRatioLower);
    }
}

function maxLiquidity(
    SqrtRatio _sqrtRatio,
    SqrtRatio sqrtRatioA,
    SqrtRatio sqrtRatioB,
    uint128 amount0,
    uint128 amount1
) pure returns (uint128) {
    uint256 sqrtRatio = _sqrtRatio.toFixed();
    (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

    if (sqrtRatio <= sqrtRatioLower) {
        return uint128(
            FixedPointMathLib.min(type(uint128).max, maxLiquidityForToken0(sqrtRatioLower, sqrtRatioUpper, amount0))
        );
    } else if (sqrtRatio < sqrtRatioUpper) {
        return uint128(
            FixedPointMathLib.min(
                type(uint128).max,
                FixedPointMathLib.min(
                    maxLiquidityForToken0(sqrtRatio, sqrtRatioUpper, amount0),
                    maxLiquidityForToken1(sqrtRatioLower, sqrtRatio, amount1)
                )
            )
        );
    } else {
        return uint128(
            FixedPointMathLib.min(type(uint128).max, maxLiquidityForToken1(sqrtRatioLower, sqrtRatioUpper, amount1))
        );
    }
}

error LiquidityDeltaOverflow();

function addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := add(liquidity, liquidityDelta)
        if and(result, shl(128, 0xffffffffffffffffffffffffffffffff)) {
            mstore(0, shl(224, 0x6d862c50))
            revert(0, 4)
        }
    }
}

function subLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := sub(liquidity, liquidityDelta)
        if and(result, shl(128, 0xffffffffffffffffffffffffffffffff)) {
            mstore(0, shl(224, 0x6d862c50))
            revert(0, 4)
        }
    }
}
