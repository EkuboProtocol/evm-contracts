// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
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
) pure returns (int128, int128) {
    if (liquidityDelta == 0) {
        return (0, 0);
    }

    bool roundUp = (liquidityDelta >= 0);
    int128 sign = liquidityDelta < 0 ? int128(-1) : int128(1);
    uint128 liquidityMag = liquidityDelta < 0 ? uint128(-liquidityDelta) : uint128(liquidityDelta);

    if (sqrtRatio <= sqrtRatioLower) {
        // Entirely in [lower, upper) range for token0
        // => token1 delta is zero
        return (sign * int128(amount0Delta(sqrtRatioLower, sqrtRatioUpper, liquidityMag, roundUp)), 0);
    } else if (sqrtRatio < sqrtRatioUpper) {
        // Partially in [lower, upper) => token0 and token1 are both affected
        int128 amt0 = sign * int128(amount0Delta(sqrtRatio, sqrtRatioUpper, liquidityMag, roundUp));
        int128 amt1 = sign * int128(amount1Delta(sqrtRatioLower, sqrtRatio, liquidityMag, roundUp));
        return (amt0, amt1);
    } else {
        // Entirely in [lower, upper) range for token1
        // => token0 delta is zero
        return (0, sign * int128(amount1Delta(sqrtRatioLower, sqrtRatioUpper, liquidityMag, roundUp)));
    }
}

error MaxLiquidityForToken0Overflow();

function maxLiquidityForToken0(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount) pure returns (uint128) {
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);
        uint256 numerator_1 = FixedPointMathLib.fullMulDivN(sqrtRatioLower, sqrtRatioUpper, 128);

        uint256 result = FixedPointMathLib.fullMulDiv(amount, numerator_1, (sqrtRatioUpper - sqrtRatioLower));

        if (result > type(uint128).max) {
            revert MaxLiquidityForToken1Overflow();
        }

        return uint128(result);
    }
}

error MaxLiquidityForToken1Overflow();

function maxLiquidityForToken1(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount) pure returns (uint128) {
    unchecked {
        (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) = sortSqrtRatios(sqrtRatioA, sqrtRatioB);

        uint256 result = (uint256(amount) << 128) / (sqrtRatioUpper - sqrtRatioLower);
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
