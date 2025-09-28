// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {computeFee, amountBeforeFee} from "./fee.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "./sqrtRatio.sol";
import {amount0Delta, amount1Delta} from "./delta.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {isPriceIncreasing} from "./isPriceIncreasing.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

// Swap Math Library
// Contains the core swap calculation logic for Ekubo Protocol
// Implements the mathematical functions needed to compute swap results including price impact, fees, and liquidity changes

/// @notice Result of a swap calculation
/// @dev Contains all the information needed to execute a swap
struct SwapResult {
    /// @notice Amount of the input token consumed by the swap
    int128 consumedAmount;
    /// @notice Amount of the output token calculated from the swap
    uint128 calculatedAmount;
    /// @notice The new sqrt price ratio after the swap
    SqrtRatio sqrtRatioNext;
    /// @notice Amount of fees collected from the swap
    uint128 feeAmount;
}

/// @notice Creates a no-operation swap result
/// @dev Used when a swap would have no effect (zero amount or already at limit price)
/// @param sqrtRatioNext The sqrt price ratio to use in the result
/// @return A SwapResult with zero amounts and the provided sqrt ratio
function noOpSwapResult(SqrtRatio sqrtRatioNext) pure returns (SwapResult memory) {
    return SwapResult({consumedAmount: 0, calculatedAmount: 0, feeAmount: 0, sqrtRatioNext: sqrtRatioNext});
}

/// @notice Thrown when the sqrt ratio limit is in the wrong direction for the swap
error SqrtRatioLimitWrongDirection();

/// @notice Computes the result of a swap given the current pool state and swap parameters
/// @dev This is the core function that calculates how a swap will affect the pool
/// @param sqrtRatio Current sqrt price ratio of the pool
/// @param liquidity Current active liquidity in the pool
/// @param sqrtRatioLimit Price limit for the swap (prevents excessive slippage)
/// @param amount Amount to swap (positive for exact input, negative for exact output)
/// @param isToken1 True if swapping token1, false if swapping token0
/// @param fee Fee rate for the pool (as a fraction of 2^64)
/// @return The calculated swap result including amounts and new price
function swapResult(
    SqrtRatio sqrtRatio,
    uint128 liquidity,
    SqrtRatio sqrtRatioLimit,
    int128 amount,
    bool isToken1,
    uint64 fee
) pure returns (SwapResult memory) {
    if (amount == 0 || sqrtRatio == sqrtRatioLimit) {
        return noOpSwapResult(sqrtRatio);
    }

    bool increasing = isPriceIncreasing(amount, isToken1);

    // We know sqrtRatio != sqrtRatioLimit because we early return above if it is
    if ((sqrtRatioLimit > sqrtRatio) != increasing) revert SqrtRatioLimitWrongDirection();

    if (liquidity == 0) {
        // if the pool is empty, the swap will always move all the way to the limit price
        return noOpSwapResult(sqrtRatioLimit);
    }

    // Pre-compute boolean flags to reduce repeated calculations
    bool isExactOut;
    assembly ("memory-safe") {
        isExactOut := slt(amount, 0)
    }

    // this amount is what moves the price
    int128 priceImpactAmount;
    if (isExactOut) {
        priceImpactAmount = amount;
    } else {
        unchecked {
            // cast is safe because amount is g.t.e. 0
            // then cast back to int128 is also safe because computeFee never returns a value g.t. the input amount
            priceImpactAmount = amount - int128(computeFee(uint128(amount), fee));
        }
    }

    // Compute next sqrt ratio - optimized token selection
    SqrtRatio sqrtRatioNextFromAmount = isToken1
        ? nextSqrtRatioFromAmount1(sqrtRatio, liquidity, priceImpactAmount)
        : nextSqrtRatioFromAmount0(sqrtRatio, liquidity, priceImpactAmount);

    // Optimized limit checking - single branchless comparison
    bool hitLimit;
    assembly ("memory-safe") {
        // Branchless limit check: (increasing && next > limit) || (!increasing && next < limit)
        let exceedsUp := and(increasing, gt(sqrtRatioNextFromAmount, sqrtRatioLimit))
        let exceedsDown := and(iszero(increasing), lt(sqrtRatioNextFromAmount, sqrtRatioLimit))
        hitLimit := or(exceedsUp, exceedsDown)
    }

    if (hitLimit) {
        // Optimized delta calculations using branchless selection
        (uint128 specifiedAmountDelta, uint128 calculatedAmountDelta) = isToken1
            ? (
                amount1Delta(sqrtRatioLimit, sqrtRatio, liquidity, !isExactOut),
                amount0Delta(sqrtRatioLimit, sqrtRatio, liquidity, isExactOut)
            )
            : (
                amount0Delta(sqrtRatioLimit, sqrtRatio, liquidity, !isExactOut),
                amount1Delta(sqrtRatioLimit, sqrtRatio, liquidity, isExactOut)
            );

        int128 consumedAmount;
        uint128 calculatedAmount;
        uint128 feeAmount;

        if (isExactOut) {
            uint128 beforeFee = amountBeforeFee(calculatedAmountDelta, fee);
            consumedAmount = -SafeCastLib.toInt128(specifiedAmountDelta);
            calculatedAmount = beforeFee;
            feeAmount = beforeFee - calculatedAmountDelta;
        } else {
            uint128 beforeFee = amountBeforeFee(specifiedAmountDelta, fee);
            consumedAmount = SafeCastLib.toInt128(beforeFee);
            calculatedAmount = calculatedAmountDelta;
            feeAmount = beforeFee - specifiedAmountDelta;
        }

        return SwapResult({
            consumedAmount: consumedAmount,
            calculatedAmount: calculatedAmount,
            sqrtRatioNext: sqrtRatioLimit,
            feeAmount: feeAmount
        });
    }

    if (sqrtRatioNextFromAmount == sqrtRatio) {
        // for an exact output swap, the price should always move because we have to round away from the current price
        // or else the pool can leak value
        assert(!isExactOut);

        return SwapResult({
            consumedAmount: amount,
            calculatedAmount: 0,
            sqrtRatioNext: sqrtRatio,
            // consume the entire input amount as fees since the price did not move
            feeAmount: uint128(amount)
        });
    }

    uint128 calculatedAmountWithoutFee = isToken1
        ? amount0Delta(sqrtRatioNextFromAmount, sqrtRatio, liquidity, isExactOut)
        : amount1Delta(sqrtRatioNextFromAmount, sqrtRatio, liquidity, isExactOut);

    uint128 calculatedAmount;
    uint128 feeAmount;

    if (isExactOut) {
        uint128 includingFee = amountBeforeFee(calculatedAmountWithoutFee, fee);
        calculatedAmount = includingFee;
        feeAmount = includingFee - calculatedAmountWithoutFee;
    } else {
        calculatedAmount = calculatedAmountWithoutFee;
        feeAmount = uint128(amount - priceImpactAmount);
    }

    return SwapResult({
        consumedAmount: amount,
        calculatedAmount: calculatedAmount,
        sqrtRatioNext: sqrtRatioNextFromAmount,
        feeAmount: feeAmount
    });
}
