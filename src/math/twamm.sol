// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";
import {computeFee} from "./fee.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Constants
uint256 constant X32 = 0x100000000; // 2**32
uint256 constant X64 = 0x10000000000000000; // 2**64
uint256 constant X128 = 0x100000000000000000000000000000000; // 2**128
uint256 constant EXPONENT_LIMIT = 1623313478486440542208; // provided limit

// Computes e^x where x is fixed–point 64.64 and the result is fixed–point 128.128.
function exp(uint128 x) pure returns (uint256) {
    if (x >= 0x20000000000000000) {
        uint256 half = exp(x / 2);
        return FixedPointMathLib.fullMulDivN(half, half, 128);
    } else {
        return expInner(x);
    }
}

// Computes e^x for x < 0x20000000000000000 as a fixed point 128.128 number
function expInner(uint128 x) pure returns (uint256) {
    require(x < 0x20000000000000000, "EXP_X_MAGNITUDE");
    unchecked {
        uint256 ratio = 0x100000000000000000000000000000000; // 2**128 in fixed–point 128.128
        if ((x & 0x1) != 0) {
            ratio = (ratio * 0xffffffffffffffff0000000000000000) >> 128;
        }
        if ((x & 0x2) != 0) {
            ratio = (ratio * 0xfffffffffffffffe0000000000000002) >> 128;
        }
        if ((x & 0x4) != 0) {
            ratio = (ratio * 0xfffffffffffffffc0000000000000008) >> 128;
        }
        if ((x & 0x8) != 0) {
            ratio = (ratio * 0xfffffffffffffff80000000000000020) >> 128;
        }
        if ((x & 0x10) != 0) {
            ratio = (ratio * 0xfffffffffffffff00000000000000080) >> 128;
        }
        if ((x & 0x20) != 0) {
            ratio = (ratio * 0xffffffffffffffe00000000000000200) >> 128;
        }
        if ((x & 0x40) != 0) {
            ratio = (ratio * 0xffffffffffffffc00000000000000800) >> 128;
        }
        if ((x & 0x80) != 0) {
            ratio = (ratio * 0xffffffffffffff800000000000002000) >> 128;
        }
        if ((x & 0x100) != 0) {
            ratio = (ratio * 0xffffffffffffff000000000000008000) >> 128;
        }
        if ((x & 0x200) != 0) {
            ratio = (ratio * 0xfffffffffffffe000000000000020000) >> 128;
        }
        if ((x & 0x400) != 0) {
            ratio = (ratio * 0xfffffffffffffc000000000000080000) >> 128;
        }
        if ((x & 0x800) != 0) {
            ratio = (ratio * 0xfffffffffffff8000000000000200000) >> 128;
        }
        if ((x & 0x1000) != 0) {
            ratio = (ratio * 0xfffffffffffff0000000000000800000) >> 128;
        }
        if ((x & 0x2000) != 0) {
            ratio = (ratio * 0xffffffffffffe0000000000002000000) >> 128;
        }
        if ((x & 0x4000) != 0) {
            ratio = (ratio * 0xffffffffffffc0000000000008000000) >> 128;
        }
        if ((x & 0x8000) != 0) {
            ratio = (ratio * 0xffffffffffff80000000000020000000) >> 128;
        }
        if ((x & 0x10000) != 0) {
            ratio = (ratio * 0xffffffffffff00000000000080000000) >> 128;
        }
        if ((x & 0x20000) != 0) {
            ratio = (ratio * 0xfffffffffffe00000000000200000000) >> 128;
        }
        if ((x & 0x40000) != 0) {
            ratio = (ratio * 0xfffffffffffc00000000000800000000) >> 128;
        }
        if ((x & 0x80000) != 0) {
            ratio = (ratio * 0xfffffffffff800000000002000000000) >> 128;
        }
        if ((x & 0x100000) != 0) {
            ratio = (ratio * 0xfffffffffff000000000008000000000) >> 128;
        }
        if ((x & 0x200000) != 0) {
            ratio = (ratio * 0xffffffffffe000000000020000000000) >> 128;
        }
        if ((x & 0x400000) != 0) {
            ratio = (ratio * 0xffffffffffc00000000007ffffffffff) >> 128;
        }
        if ((x & 0x800000) != 0) {
            ratio = (ratio * 0xffffffffff80000000001ffffffffffb) >> 128;
        }
        if ((x & 0x1000000) != 0) {
            ratio = (ratio * 0xffffffffff00000000007fffffffffd5) >> 128;
        }
        if ((x & 0x2000000) != 0) {
            ratio = (ratio * 0xfffffffffe0000000001fffffffffeab) >> 128;
        }
        if ((x & 0x4000000) != 0) {
            ratio = (ratio * 0xfffffffffc0000000007fffffffff555) >> 128;
        }
        if ((x & 0x8000000) != 0) {
            ratio = (ratio * 0xfffffffff8000000001fffffffffaaab) >> 128;
        }
        if ((x & 0x10000000) != 0) {
            ratio = (ratio * 0xfffffffff0000000007ffffffffd5555) >> 128;
        }
        if ((x & 0x20000000) != 0) {
            ratio = (ratio * 0xffffffffe000000001ffffffffeaaaab) >> 128;
        }
        if ((x & 0x40000000) != 0) {
            ratio = (ratio * 0xffffffffc000000007ffffffff555555) >> 128;
        }
        if ((x & 0x80000000) != 0) {
            ratio = (ratio * 0xffffffff800000001ffffffffaaaaaab) >> 128;
        }
        if ((x & 0x100000000) != 0) {
            ratio = (ratio * 0xffffffff000000007fffffffd5555555) >> 128;
        }
        if ((x & 0x200000000) != 0) {
            ratio = (ratio * 0xfffffffe00000001fffffffeaaaaaaab) >> 128;
        }
        if ((x & 0x400000000) != 0) {
            ratio = (ratio * 0xfffffffc00000007fffffff555555560) >> 128;
        }
        if ((x & 0x800000000) != 0) {
            ratio = (ratio * 0xfffffff80000001fffffffaaaaaaab55) >> 128;
        }
        if ((x & 0x1000000000) != 0) {
            ratio = (ratio * 0xfffffff00000007ffffffd5555556000) >> 128;
        }
        if ((x & 0x2000000000) != 0) {
            ratio = (ratio * 0xffffffe0000001ffffffeaaaaaab5555) >> 128;
        }
        if ((x & 0x4000000000) != 0) {
            ratio = (ratio * 0xffffffc0000007ffffff555555600000) >> 128;
        }
        if ((x & 0x8000000000) != 0) {
            ratio = (ratio * 0xffffff8000001ffffffaaaaaab555555) >> 128;
        }
        if ((x & 0x10000000000) != 0) {
            ratio = (ratio * 0xffffff0000007fffffd555555ffffffe) >> 128;
        }
        if ((x & 0x20000000000) != 0) {
            ratio = (ratio * 0xfffffe000001fffffeaaaaab55555511) >> 128;
        }
        if ((x & 0x40000000000) != 0) {
            ratio = (ratio * 0xfffffc000007fffff555555ffffff777) >> 128;
        }
        if ((x & 0x80000000000) != 0) {
            ratio = (ratio * 0xfffff800001fffffaaaaab5555544444) >> 128;
        }
        if ((x & 0x100000000000) != 0) {
            ratio = (ratio * 0xfffff000007ffffd55555fffffddddde) >> 128;
        }
        if ((x & 0x200000000000) != 0) {
            ratio = (ratio * 0xffffe00001ffffeaaaab555551111128) >> 128;
        }
        if ((x & 0x400000000000) != 0) {
            ratio = (ratio * 0xffffc00007ffff55555fffff77777d28) >> 128;
        }
        if ((x & 0x800000000000) != 0) {
            ratio = (ratio * 0xffff80001ffffaaaab5555444445b05b) >> 128;
        }
        if ((x & 0x1000000000000) != 0) {
            ratio = (ratio * 0xffff00007fffd5555ffffdddde38e381) >> 128;
        }
        if ((x & 0x2000000000000) != 0) {
            ratio = (ratio * 0xfffe0001fffeaaab5555111127d276a7) >> 128;
        }
        if ((x & 0x4000000000000) != 0) {
            ratio = (ratio * 0xfffc0007fff5555ffff7777d27cf3cf5) >> 128;
        }
        if ((x & 0x8000000000000) != 0) {
            ratio = (ratio * 0xfff8001fffaaab55544445b0596597f9) >> 128;
        }
        if ((x & 0x10000000000000) != 0) {
            ratio = (ratio * 0xfff0007ffd555fffddde38e2be2d82d5) >> 128;
        }
        if ((x & 0x20000000000000) != 0) {
            ratio = (ratio * 0xffe001ffeaab55511127d21522f2295c) >> 128;
        }
        if ((x & 0x40000000000000) != 0) {
            ratio = (ratio * 0xffc007ff555fff777d279e7b87acece0) >> 128;
        }
        if ((x & 0x80000000000000) != 0) {
            ratio = (ratio * 0xff801ffaab554445b04105b043e8f48d) >> 128;
        }
        if ((x & 0x100000000000000) != 0) {
            ratio = (ratio * 0xff007fd55ffdde38d68f08c257e0ce3f) >> 128;
        }
        if ((x & 0x200000000000000) != 0) {
            ratio = (ratio * 0xfe01feab551127cbfe5f89994c44216f) >> 128;
        }
        if ((x & 0x400000000000000) != 0) {
            ratio = (ratio * 0xfc07f55ff77d2493e885eeaa756ad523) >> 128;
        }
        if ((x & 0x800000000000000) != 0) {
            ratio = (ratio * 0xf81fab5445aebc8a58055fcbbb139ae9) >> 128;
        }
        if ((x & 0x1000000000000000) != 0) {
            ratio = (ratio * 0xf07d5fde38151e72f18ff03049ac5d7f) >> 128;
        }
        if ((x & 0x2000000000000000) != 0) {
            ratio = (ratio * 0xe1eb51276c110c3c3eb1269f2f5d4afb) >> 128;
        }
        if ((x & 0x4000000000000000) != 0) {
            ratio = (ratio * 0xc75f7cf564105743415cbc9d6368f3b9) >> 128;
        }
        if ((x & 0x8000000000000000) != 0) {
            ratio = (ratio * 0x9b4597e37cb04ff3d675a35530cdd768) >> 128;
        }
        if ((x & 0x10000000000000000) != 0) {
            ratio = (ratio * 0x5e2d58d8b3bcdf1abadec7829054f90e) >> 128;
        }
        if (x != 0) {
            ratio = type(uint256).max / ratio;
        }
        return ratio;
    }
}

error SaleRateOverflow();

// Computes sale rate = (amount * X32) / duration, and tries to cast it to 112 bits.
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

// Computes c = (sqrtSaleRatio - sqrtRatio) / (sqrtSaleRatio + sqrtRatio) and a sign flag.
function calculateC(uint256 sqrtRatio, uint256 sqrtSaleRatio, bool roundUp) pure returns (uint256, bool) {
    if (sqrtRatio == sqrtSaleRatio) {
        return (0, false);
    } else if (sqrtRatio == 0) {
        return (X128, false);
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
        return (c, sign);
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
        sqrtSaleRatio = FixedPointMathLib.sqrt(saleRatio) * X64;
    }
    uint256 sqrtRatioFixed = sqrtRatio.toFixed();
    bool roundUp = sqrtRatioFixed > sqrtSaleRatio;
    (uint256 c, bool sign) = calculateC(sqrtRatioFixed, sqrtSaleRatio, roundUp);
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
                : FixedPointMathLib.mulDiv(sqrtSaleRatio, scale, X128);
        }
    }
    // assert these cases never happen in the tests
    // require(sqrtRatioNext < maxSqrtRatio(), "SQRT_RATIO_NEXT_TOO_HIGH");
    // require(sqrtRatioNext >= minSqrtRatio(), "SQRT_RATIO_NEXT_TOO_LOW");
    return toSqrtRatio(sqrtRatioNext, roundUp);
}
