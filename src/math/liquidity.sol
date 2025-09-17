// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {amount0Delta, amount1Delta, sortAndConvertToFixedSqrtRatios} from "./delta.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

/// @title Liquidity Math Library
/// @notice Contains functions for calculating liquidity-related amounts and conversions
/// @dev Provides utilities for converting between liquidity changes and token amounts

/// @notice Returns the token0 and token1 delta owed for a given change in liquidity
/// @dev Calculates the token amounts required or returned when liquidity is added or removed from a position
/// @param sqrtRatio Current price (as a sqrt ratio)
/// @param liquidityDelta Signed liquidity change; positive = added, negative = removed
/// @param sqrtRatioLower The lower bound of the price range (as a sqrt ratio)
/// @param sqrtRatioUpper The upper bound of the price range (as a sqrt ratio)
/// @return delta0 The change in token0 amount
/// @return delta1 The change in token1 amount
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

/// @notice Calculates the maximum liquidity that can be provided with a given amount of token0
/// @dev Used when the current price is below the position's range (only token0 is needed)
/// @param sqrtRatioLower The lower sqrt price ratio of the position
/// @param sqrtRatioUpper The upper sqrt price ratio of the position
/// @param amount The amount of token0 available
/// @return The maximum liquidity that can be provided
function maxLiquidityForToken0(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 amount) pure returns (uint256) {
    unchecked {
        uint256 numerator1 = FixedPointMathLib.fullMulDivN(sqrtRatioLower, sqrtRatioUpper, 128);

        return FixedPointMathLib.fullMulDiv(amount, numerator1, (sqrtRatioUpper - sqrtRatioLower));
    }
}

/// @notice Calculates the maximum liquidity that can be provided with a given amount of token1
/// @dev Used when the current price is above the position's range (only token1 is needed)
/// @param sqrtRatioLower The lower sqrt price ratio of the position
/// @param sqrtRatioUpper The upper sqrt price ratio of the position
/// @param amount The amount of token1 available
/// @return The maximum liquidity that can be provided
function maxLiquidityForToken1(uint256 sqrtRatioLower, uint256 sqrtRatioUpper, uint128 amount) pure returns (uint256) {
    unchecked {
        return (uint256(amount) << 128) / (sqrtRatioUpper - sqrtRatioLower);
    }
}

/// @notice Calculates the maximum liquidity that can be provided given amounts of both tokens
/// @dev Determines the limiting factor between token0 and token1 based on current price and position bounds
/// @param _sqrtRatio Current sqrt price ratio
/// @param sqrtRatioA One bound of the position (will be sorted with sqrtRatioB)
/// @param sqrtRatioB Other bound of the position (will be sorted with sqrtRatioA)
/// @param amount0 Available amount of token0
/// @param amount1 Available amount of token1
/// @return The maximum liquidity that can be provided with the given token amounts
function maxLiquidity(
    SqrtRatio _sqrtRatio,
    SqrtRatio sqrtRatioA,
    SqrtRatio sqrtRatioB,
    uint128 amount0,
    uint128 amount1
) pure returns (uint128) {
    uint256 sqrtRatio = _sqrtRatio.toFixed();
    (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

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

/// @notice Thrown when a liquidity delta operation would cause overflow
error LiquidityDeltaOverflow();

/// @notice Safely adds a liquidity delta to a liquidity amount
/// @dev Reverts if the operation would cause overflow or underflow
/// @param liquidity The current liquidity amount
/// @param liquidityDelta The change in liquidity (can be positive or negative)
/// @return result The new liquidity amount after applying the delta
function addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := add(liquidity, liquidityDelta)
        if and(result, shl(128, 0xffffffffffffffffffffffffffffffff)) {
            mstore(0, shl(224, 0x6d862c50))
            revert(0, 4)
        }
    }
}

/// @notice Safely subtracts a liquidity delta from a liquidity amount
/// @dev Reverts if the operation would cause overflow or underflow
/// @param liquidity The current liquidity amount
/// @param liquidityDelta The change in liquidity to subtract
/// @return result The new liquidity amount after subtracting the delta
function subLiquidityDelta(uint128 liquidity, int128 liquidityDelta) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := sub(liquidity, liquidityDelta)
        if and(result, shl(128, 0xffffffffffffffffffffffffffffffff)) {
            mstore(0, shl(224, 0x6d862c50))
            revert(0, 4)
        }
    }
}
