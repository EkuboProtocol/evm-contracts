// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {amount0Delta, amount1Delta} from "./delta.sol";

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
