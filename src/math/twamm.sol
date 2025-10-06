// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";
import {computeFee} from "./fee.sol";
import {exp2} from "./exp2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error SaleRateOverflow();

/// @dev Computes sale rate = (amount << 32) / duration and reverts if the result exceeds type(uint112).max.
/// @dev Assumes duration > 0 and amount <= type(uint224).max.
function computeSaleRate(uint256 amount, uint256 duration) pure returns (uint256 saleRate) {
    assembly ("memory-safe") {
        saleRate := div(shl(32, amount), duration)
        if shr(112, saleRate) {
            // cast sig "SaleRateOverflow()"
            mstore(0, shl(224, 0x83c87460))
            revert(0, 4)
        }
    }
}

error SaleRateDeltaOverflow();

/// @dev Adds the sale rate delta to the saleRate and reverts if the result is greater than type(uint112).max
/// @dev Assumes saleRate <= type(uint112).max and saleRateDelta <= type(int112).max and saleRateDelta >= type(int112).min
function addSaleRateDelta(uint256 saleRate, int256 saleRateDelta) pure returns (uint256 result) {
    assembly ("memory-safe") {
        result := add(saleRate, saleRateDelta)
        // if any of the upper bits are non-zero, revert
        if shr(112, result) {
            // cast sig "SaleRateDeltaOverflow()"
            mstore(0, shl(224, 0xc902643d))
            revert(0, 4)
        }
    }
}

/// @dev Computes amount from sale rate: (saleRate * duration) >> 32, with optional rounding.
/// @dev Assumes the saleRate <= type(uint112).max and duration <= type(uint32).max
function computeAmountFromSaleRate(uint256 saleRate, uint256 duration, bool roundUp) pure returns (uint256 amount) {
    assembly ("memory-safe") {
        amount := shr(32, add(mul(saleRate, duration), mul(0xffffffff, roundUp)))
    }
}

/// @dev Computes reward amount = (rewardRate * saleRate) >> 128.
/// @dev saleRate is assumed to be <= type(uint112).max, thus this function is never expected to overflow
function computeRewardAmount(uint256 rewardRate, uint256 saleRate) pure returns (uint128) {
    return uint128(FixedPointMathLib.fullMulDivN(rewardRate, saleRate, 128));
}

/// @dev Computes the quantity `c = (sqrtSaleRatio - sqrtRatio) / (sqrtSaleRatio + sqrtRatio)` as a signed 64.128 number
/// @dev sqrtRatio is assumed to be between 2**192 and 2**-64, while sqrtSaleRatio values are assumed to be between 2**184 and 2**-72
function computeC(uint256 sqrtRatio, uint256 sqrtSaleRatio) pure returns (int256 c) {
    uint256 unsigned = FixedPointMathLib.fullMulDiv(
        FixedPointMathLib.dist(sqrtRatio, sqrtSaleRatio), (1 << 128), sqrtRatio + sqrtSaleRatio
    );
    assembly ("memory-safe") {
        let sign := sub(shl(1, gt(sqrtSaleRatio, sqrtRatio)), 1)
        c := mul(sign, unsigned)
    }
}

/// @dev Returns a 64.128 number representing the sqrt sale ratio
/// @dev Assumes both saleRateToken0 and saleRateToken1 are nonzero and <= type(uint112).max
function computeSqrtSaleRatio(uint256 saleRateToken0, uint256 saleRateToken1) pure returns (uint256 sqrtSaleRatio) {
    unchecked {
        uint256 saleRatio = FixedPointMathLib.rawDiv(saleRateToken1 << 128, saleRateToken0);

        if (saleRatio <= type(uint128).max) {
            // full precision for small ratios
            sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio << 128);
        } else if (saleRatio <= type(uint192).max) {
            // we know it only has 192 bits, so we can shift it 64 before rooting to get more precision
            sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio << 64) << 32;
        } else {
            // we assume it has max 240 bits, since saleRateToken1 is 112 bits and we shifted left 128
            sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio << 16) << 56;
        }
    }
}

/// @dev Computes the next sqrt ratio according to the state of the TWAMM for a fixed sale rate
/// @dev Assumes both sale rates are != 0 and <= type(uint112).max
/// @dev Assumes liquidity is <= type(uint128).max
/// @dev Assumes timeElapsed is <= type(uint32).max
function computeNextSqrtRatio(
    SqrtRatio sqrtRatio,
    uint256 liquidity,
    uint256 saleRateToken0,
    uint256 saleRateToken1,
    uint256 timeElapsed,
    uint64 fee
) pure returns (SqrtRatio sqrtRatioNext) {
    unchecked {
        // assumed:
        //   assert(saleRateToken0 != 0 && saleRateToken1 != 0);
        uint256 sqrtSaleRatio = computeSqrtSaleRatio(saleRateToken0, saleRateToken1);

        uint256 sqrtRatioFixed = sqrtRatio.toFixed();
        bool roundUp = sqrtRatioFixed > sqrtSaleRatio;

        int256 c = computeC(sqrtRatioFixed, sqrtSaleRatio);

        if (c == 0 || liquidity == 0) {
            // if liquidity is 0, we just settle the ratio of sale rates since the liquidity provides no friction to the price movement
            // if c is 0, that means the difference b/t sale ratio and sqrt ratio is too small to be detected
            // so we just assume it settles at the sale ratio
            sqrtRatioNext = toSqrtRatio(sqrtSaleRatio, roundUp);
        } else {
            uint256 sqrtSaleRateWithoutFee = FixedPointMathLib.sqrt(saleRateToken0 * saleRateToken1);
            // max 112 bits
            uint256 sqrtSaleRate = sqrtSaleRateWithoutFee - computeFee(uint128(sqrtSaleRateWithoutFee), fee);

            // (12392656037 * t * sqrtSaleRate) / liquidity == (34 + 32 + 128) - 128 bits, cannot overflow
            // uint256(12392656037) = Math.floor(Math.LOG2E * 2**33).
            // this combines the doubling, the left shifting and the converting to a base 2 exponent into a single multiplication
            uint256 exponent = FixedPointMathLib.rawDiv(sqrtSaleRate * timeElapsed * 12392656037, liquidity);
            if (exponent >= 0x400000000000000000) {
                // if the exponent is larger than this value (64), the exponent term dominates and the result is approximately the sell ratio
                sqrtRatioNext = toSqrtRatio(sqrtSaleRatio, roundUp);
            } else {
                int256 ePowExponent = int256(uint256(exp2(uint128(exponent))) << 64);

                uint256 sqrtRatioNextFixed = FixedPointMathLib.fullMulDiv(
                    sqrtSaleRatio, FixedPointMathLib.dist(ePowExponent, c), FixedPointMathLib.abs(ePowExponent + c)
                );

                // we should never exceed the sale ratio
                if (roundUp) {
                    sqrtRatioNextFixed = FixedPointMathLib.max(sqrtRatioNextFixed, sqrtSaleRatio);
                } else {
                    sqrtRatioNextFixed = FixedPointMathLib.min(sqrtRatioNextFixed, sqrtSaleRatio);
                }

                sqrtRatioNext = toSqrtRatio(sqrtRatioNextFixed, roundUp);
            }
        }
    }
}
