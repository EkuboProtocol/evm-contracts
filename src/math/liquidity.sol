// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {amount0Delta, amount1Delta, sortSqrtRatios} from "./delta.sol";

/**
 * @notice Returns the token0 and token1 delta owed for a given change in liquidity.
 * @param sqrtRatio        Current price (as a sqrt ratio).
 * @param liquidityDelta   Signed liquidity change; positive = added, negative = removed.
 * @param sqrtRatioLower   The lower bound of the price range (as a sqrt ratio).
 * @param sqrtRatioUpper   The upper bound of the price range (as a sqrt ratio).
 */
function liquidityDeltaToAmountDelta(
    uint256 sqrtRatio,
    int128 liquidityDelta,
    uint256 sqrtRatioLower,
    uint256 sqrtRatioUpper
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

error MaxLiquidityForToken0Overflow();

function maxLiquidityForToken0(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount) pure returns (uint128) {
    unchecked {
        (sqrtRatioA, sqrtRatioB) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);
        uint256 numerator_1 = FixedPointMathLib.fullMulDivN(sqrtRatioA, sqrtRatioB, 128);

        uint256 result = FixedPointMathLib.fullMulDiv(amount, numerator_1, (sqrtRatioB - sqrtRatioA));

        if (result > type(uint128).max) {
            revert MaxLiquidityForToken1Overflow();
        }

        return uint128(result);
    }
}

error MaxLiquidityForToken1Overflow();

function maxLiquidityForToken1(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount) pure returns (uint128) {
    unchecked {
        (sqrtRatioA, sqrtRatioB) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

        uint256 result = (uint256(amount) << 128) / (sqrtRatioB - sqrtRatioA);
        if (result > type(uint128).max) {
            revert MaxLiquidityForToken1Overflow();
        }
        return uint128(result);
    }
}

function maxLiquidity(uint256 sqrtRatio, uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount0, uint128 amount1)
    pure
    returns (uint128)
{
    (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

    if (sqrtRatio <= sqrtRatioLower) {
        return maxLiquidityForToken0(sqrtRatioLower, sqrtRatioUpper, amount0);
    } else if (sqrtRatio < sqrtRatioUpper) {
        uint128 maxFromToken0 = maxLiquidityForToken0(sqrtRatio, sqrtRatioUpper, amount0);
        uint128 maxFromToken1 = maxLiquidityForToken1(sqrtRatioLower, sqrtRatio, amount1);

        return uint128(FixedPointMathLib.min(maxFromToken0, maxFromToken1));
    } else {
        return maxLiquidityForToken1(sqrtRatioLower, sqrtRatioUpper, amount1);
    }
}

error LiquidityUnderflow();
error LiquidityOverflow();

function addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128) {
    unchecked {
        int256 l = int256(uint256(liquidity));
        int256 lNext = l + liquidityDelta;

        if (lNext < 0) revert LiquidityUnderflow();
        if (lNext > 0xffffffffffffffffffffffffffffffff) revert LiquidityOverflow();

        return uint128(uint256(lNext));
    }
}

function subLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128) {
    unchecked {
        int256 l = int256(uint256(liquidity));
        int256 lNext = l - liquidityDelta;

        if (lNext < 0) revert LiquidityUnderflow();
        if (lNext > 0xffffffffffffffffffffffffffffffff) revert LiquidityOverflow();

        return uint128(uint256(lNext));
    }
}
