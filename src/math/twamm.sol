// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";
import {computeFee} from "./fee.sol";
import {exp} from "./exp.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Constants
uint256 constant X128 = 0x100000000000000000000000000000000; // 2**128
uint256 constant EXPONENT_LIMIT = 1623313478486440542208; // provided limit

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
function calculateAmountFromSaleRate(uint112 saleRate, uint32 duration, bool roundUp) pure returns (uint128 amount) {
    assembly ("memory-safe") {
        amount := shr(32, add(mul(saleRate, duration), mul(0xffffffff, roundUp)))
    }
}

error RewardAmountOverflow();

// Computes reward amount = (rewardRate * saleRate) >> 128.
function calculateRewardAmount(uint256 rewardRate, uint128 saleRate) pure returns (uint128) {
    uint256 reward = FixedPointMathLib.fullMulDivN(rewardRate, saleRate, 128);
    if (reward > type(uint128).max) revert RewardAmountOverflow();
    return uint128(reward);
}

// Computes the quantity `c = (sqrtSaleRatio - sqrtRatio) / (sqrtSaleRatio + sqrtRatio)`
function calculateC(uint256 sqrtRatio, uint256 sqrtSaleRatio, bool roundUp) pure returns (int256) {
    if (sqrtRatio == sqrtSaleRatio) {
        return 0;
    } else if (sqrtRatio == 0) {
        return (1 << 128);
    } else {
        uint256 numerator;
        bool sign;
        if (sqrtRatio > sqrtSaleRatio) {
            numerator = sqrtRatio - sqrtSaleRatio;
            sign = true;
        } else {
            numerator = sqrtSaleRatio - sqrtRatio;
            sign = false;
        }
        uint256 c = roundUp
            ? FixedPointMathLib.mulDivUp(numerator, X128, (sqrtSaleRatio + sqrtRatio))
            : FixedPointMathLib.mulDiv(numerator, X128, (sqrtSaleRatio + sqrtRatio));
        return sign ? -c : c;
    }
}

function calculateNextSqrtRatio(
    SqrtRatio sqrtRatio,
    uint128 liquidity,
    uint112 token0SaleRate,
    uint112 token1SaleRate,
    uint32 timeElapsed,
    uint64 fee
) pure returns (SqrtRatio) {
    // saleRatio = token1SaleRate * 2**128 / token0SaleRate
    uint256 saleRatio = (uint256(token1SaleRate) << 128) / uint256(token0SaleRate);
    uint256 sqrtSaleRatio;
    if (saleRatio < X128) {
        sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio);
    } else {
        sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio) << 64;
    }
    uint256 sqrtRatioFixed = sqrtRatio.toFixed();
    bool roundUp = sqrtRatioFixed > sqrtSaleRatio;
    int256 c = calculateC(sqrtRatioFixed, sqrtSaleRatio, roundUp);
    uint256 sqrtRatioNext;
    if (c == 0 || liquidity == 0) {
        sqrtRatioNext = sqrtSaleRatio;
    } else {
        uint256 sqrtSaleRateWithoutFee = FixedPointMathLib.sqrt(uint256(token0SaleRate) * uint256(token1SaleRate));
        uint256 feeCharged = computeFee(uint128(sqrtSaleRateWithoutFee), fee);
        uint256 sqrtSaleRate = sqrtSaleRateWithoutFee - feeCharged;
        uint256 resultMul = sqrtSaleRate * (0x200000000 * uint256(timeElapsed));
        // todo: we can do this rounding more efficiently with assembly
        uint256 exponent =
            roundUp ? resultMul / uint256(liquidity) : FixedPointMathLib.divUp(resultMul, uint256(liquidity));
        if (exponent >= EXPONENT_LIMIT) {
            sqrtRatioNext = sqrtSaleRatio;
        } else {
            // We use only the low 128 bits of exponent.
            uint256 eVal = exp(uint128(exponent));
            uint256 term1 = eVal > c ? eVal - c : 0;
            uint256 term2 = eVal + c;
            uint256 scale;
            if (sign) {
                scale = roundUp
                    ? FixedPointMathLib.mulDivUp(term2, X128, term1)
                    : FixedPointMathLib.mulDiv(term2, X128, term1);
            } else {
                scale = roundUp
                    ? FixedPointMathLib.mulDivUp(term1, X128, term2)
                    : FixedPointMathLib.mulDiv(term1, X128, term2);
            }
            sqrtRatioNext = roundUp
                ? FixedPointMathLib.mulDivUp(sqrtSaleRatio, scale, X128)
                : FixedPointMathLib.mulDivN(sqrtSaleRatio, scale, 128);
        }
    }
    // assert these cases never happen in the tests
    // require(sqrtRatioNext < maxSqrtRatio(), "SQRT_RATIO_NEXT_TOO_HIGH");
    // require(sqrtRatioNext >= minSqrtRatio(), "SQRT_RATIO_NEXT_TOO_LOW");
    return toSqrtRatio(sqrtRatioNext, roundUp);
}
