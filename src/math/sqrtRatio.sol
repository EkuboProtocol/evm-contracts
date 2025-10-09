// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio, toSqrtRatio, MAX_FIXED_VALUE_ROUND_UP} from "../types/sqrtRatio.sol";

// Compute the next ratio from a delta amount0, always rounded towards starting price for input, and
// away from starting price for output
/// @dev Assumes sqrt ratio and liquidity are non-zero
function nextSqrtRatioFromAmount0(SqrtRatio _sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (SqrtRatio sqrtRatioNext)
{
    if (amount == 0) {
        return _sqrtRatio;
    }

    uint256 sqrtRatio = _sqrtRatio.toFixed();

    uint256 liquidityX128;
    assembly ("memory-safe") {
        liquidityX128 := shl(128, liquidity)
    }

    if (amount < 0) {
        uint256 amountAbs;
        assembly ("memory-safe") {
            amountAbs := sub(0, amount)
        }
        unchecked {
            // multiplication will revert on overflow, so we return the maximum value for the type
            if (amountAbs > FixedPointMathLib.rawDiv(type(uint256).max, sqrtRatio)) {
                return SqrtRatio.wrap(type(uint96).max);
            }

            uint256 product = sqrtRatio * amountAbs;

            // again it will overflow if this is the case, so return the max value
            if (product >= liquidityX128) {
                return SqrtRatio.wrap(type(uint96).max);
            }

            uint256 denominator = liquidityX128 - product;

            uint256 resultFixed = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);

            if (resultFixed > MAX_FIXED_VALUE_ROUND_UP) {
                return SqrtRatio.wrap(type(uint96).max);
            }

            sqrtRatioNext = toSqrtRatio(resultFixed, true);
        }
    } else {
        uint256 sqrtRatioRaw;
        assembly ("memory-safe") {
            // this can never overflow, amountAbs is limited to 2**128-1 and liquidityX128 / sqrtRatio is limited to (2**128-1 << 128)
            // adding the 2 values can at most equal type(uint256).max
            let denominator := add(div(liquidityX128, sqrtRatio), amount)
            sqrtRatioRaw := add(div(liquidityX128, denominator), iszero(iszero(mod(liquidityX128, denominator))))
        }

        sqrtRatioNext = toSqrtRatio(sqrtRatioRaw, true);
    }
}

/// @dev Assumes liquidity is non-zero
function nextSqrtRatioFromAmount1(SqrtRatio _sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (SqrtRatio sqrtRatioNext)
{
    if (amount == 0) {
        return _sqrtRatio;
    }

    uint256 sqrtRatio = _sqrtRatio.toFixed();

    unchecked {
        uint256 liquidityU256;
        assembly ("memory-safe") {
            liquidityU256 := liquidity
        }

        if (amount < 0) {
            uint256 quotient;
            assembly ("memory-safe") {
                let numerator := shl(128, sub(0, amount))
                quotient := add(div(numerator, liquidityU256), iszero(iszero(mod(numerator, liquidityU256))))
            }

            uint256 sqrtRatioNextFixed = FixedPointMathLib.zeroFloorSub(sqrtRatio, quotient);

            sqrtRatioNext = toSqrtRatio(sqrtRatioNextFixed, false);
        } else {
            uint256 quotient;
            assembly ("memory-safe") {
                quotient := div(shl(128, amount), liquidityU256)
            }
            uint256 sum = sqrtRatio + quotient;
            if (sum < sqrtRatio || sum > type(uint192).max) {
                return SqrtRatio.wrap(type(uint96).max);
            }
            sqrtRatioNext = toSqrtRatio(sum, false);
        }
    }
}
