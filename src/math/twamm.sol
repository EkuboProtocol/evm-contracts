// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";
import {computeFee} from "./fee.sol";
import {exp} from "./exp.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error SaleRateOverflow();

// Computes sale rate = (amount << 32) / duration, and tries to cast it to 112 bits.
function calculateSaleRate(uint128 amount, uint32 duration) pure returns (uint112) {
    unchecked {
        uint256 saleRate = (uint256(amount) << 32) / duration;
        if (saleRate > type(uint112).max) revert SaleRateOverflow();
        return uint112(saleRate);
    }
}

// Computes amount from sale rate: (saleRate * duration) >> 32, with optional rounding.
// Cannot overflow since max sale rate times max result fits in 112 bits
function calculateAmountFromSaleRate(uint112 saleRate, uint32 duration, bool roundUp) pure returns (uint256 amount) {
    assembly ("memory-safe") {
        amount := shr(32, add(mul(saleRate, duration), mul(0xffffffff, roundUp)))
    }
}

error RewardAmountOverflow();

// Computes reward amount = (rewardRate * saleRate) >> 128.
function calculateRewardAmount(uint256 rewardRate, uint112 saleRate) pure returns (uint128) {
    uint256 reward = FixedPointMathLib.fullMulDivN(rewardRate, saleRate, 128);
    if (reward > type(uint128).max) revert RewardAmountOverflow();
    return uint128(reward);
}

// Computes the quantity `c = (sqrtSaleRatio - sqrtRatio) / (sqrtSaleRatio + sqrtRatio)` as a signed 64.64 number
// Note that the sqrtRatio is assumed to be between 2**192 and 2**-64, while sqrtSaleRatio values are assumed to be between 2**184 and 2**-72
function calculateC(uint256 sqrtRatio, uint256 sqrtSaleRatio) pure returns (int256 c) {
    assembly ("memory-safe") {
        c := sdiv(shl(64, sub(sqrtSaleRatio, sqrtRatio)), add(sqrtSaleRatio, sqrtRatio))
    }
}

function calculateNextSqrtRatio(
    SqrtRatio sqrtRatio,
    uint128 liquidity,
    uint112 saleRateToken0,
    uint112 saleRateToken1,
    uint32 timeElapsed,
    uint64 fee
) pure returns (SqrtRatio sqrtRatioNext) {
    unchecked {
        uint256 saleRatio = (uint256(saleRateToken1) << 128) / saleRateToken0;
        // we compute this value as a 64.128 number
        uint256 sqrtSaleRatio;
        if (saleRatio > type(uint128).max) {
            sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio) << 64;
        } else {
            sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio << 128);
        }

        uint256 sqrtRatioFixed = sqrtRatio.toFixed();
        bool roundUp = sqrtRatioFixed > sqrtSaleRatio;

        int256 c = calculateC(sqrtRatioFixed, sqrtSaleRatio);

        if (c == 0 || liquidity == 0) {
            // if liquidity is 0, we just settle the ratio of sale rates since the liquidity provides no friction to the price movement
            // if c is 0, that means the difference b/t sale ratio and sqrt ratio is too small to be detected
            // so we just assume it settles at the sale ratio
            sqrtRatioNext = toSqrtRatio(sqrtSaleRatio, roundUp);
        } else {
            uint256 sqrtSaleRateWithoutFee = FixedPointMathLib.sqrt(uint256(saleRateToken0) * saleRateToken1);
            // max 112 bits
            uint256 sqrtSaleRate = sqrtSaleRateWithoutFee - computeFee(uint128(sqrtSaleRateWithoutFee), fee);

            // (2 * t * sqrtSaleRate) / liquidity == (1 + 32 + 112) - 128 bits, cannot overflow
            uint256 exponent = ((sqrtSaleRate * uint256(timeElapsed)) << 33) / uint256(liquidity);
            if (exponent >= 1623313478486440542208) {
                // if the exponent is larger than this value (~88), the exponent term dominates and the result is approximately the sell ratio
                sqrtRatioNext = toSqrtRatio(sqrtSaleRatio, roundUp);
            } else {
                int256 ePowExponent = int256(exp(uint128(exponent)) >> 64);

                sqrtRatioNext = toSqrtRatio(
                    FixedPointMathLib.fullMulDiv(
                        sqrtSaleRatio, FixedPointMathLib.abs(ePowExponent - c), FixedPointMathLib.abs(ePowExponent + c)
                    ),
                    roundUp
                );
            }
        }
    }
}
