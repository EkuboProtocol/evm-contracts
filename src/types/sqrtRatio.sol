// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// A 64.63 number or a 0.127 number, where the most significant bit indicates whether it's a 64.63 number or a 0.127 number
// The goal is to have at least 63 bits of precision for all supported prices
type SqrtRatio is uint128;

SqrtRatio constant MIN_SQRT_RATIO = SqrtRatio.wrap(9223595582101085263);
SqrtRatio constant MAX_SQRT_RATIO = SqrtRatio.wrap(340278243338933430587873239885483909143);
SqrtRatio constant ONE = SqrtRatio.wrap((1 << 127) + (1 << 63));

using {toFixed, isValid, ge as >=, le as <=, lt as <, gt as >, eq as ==, neq as !=, sub} for SqrtRatio global;

uint128 constant TWO_POW_127 = 0x80000000000000000000000000000000;

error ValueOverflowsSqrtRatioContainer();

function isValid(SqrtRatio sqrtRatio) pure returns (bool) {
    uint128 v = SqrtRatio.unwrap(sqrtRatio);
    return (v < TWO_POW_127 && v >= SqrtRatio.unwrap(MIN_SQRT_RATIO))
        || (v >= SqrtRatio.unwrap(ONE) && v <= SqrtRatio.unwrap(MAX_SQRT_RATIO));
}

// Converts a 64.128 value into the compact SqrtRatio representation
function toSqrtRatio(uint256 sqrtRatio, bool roundUp) pure returns (SqrtRatio) {
    unchecked {
        if (sqrtRatio > type(uint128).max) {
            if (sqrtRatio > type(uint192).max) revert ValueOverflowsSqrtRatioContainer();
            return roundUp
                ? SqrtRatio.wrap(uint128(TWO_POW_127 | ((sqrtRatio + 0x1ffffffffffffffff) >> 65)))
                : SqrtRatio.wrap(uint128(TWO_POW_127 | (sqrtRatio >> 65)));
        } else {
            if (roundUp) {
                if (sqrtRatio == type(uint128).max) {
                    return ONE;
                } else {
                    return SqrtRatio.wrap(uint128((sqrtRatio + 1) >> 1));
                }
            } else {
                return SqrtRatio.wrap(uint128(sqrtRatio >> 1));
            }
        }
    }
}

error InvalidSqrtRatioToFixed();

// Returns a 64.128 value for the given sqrt ratio
function toFixed(SqrtRatio sqrtRatio) pure returns (uint256) {
    uint128 value = SqrtRatio.unwrap(sqrtRatio);
    if (value & TWO_POW_127 != 0) {
        if (value < SqrtRatio.unwrap(ONE)) revert InvalidSqrtRatioToFixed();
        return uint256(value - TWO_POW_127) << 65;
    } else {
        return uint256(value) << 1;
    }
}

function le(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) <= SqrtRatio.unwrap(b);
}

function lt(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) < SqrtRatio.unwrap(b);
}

function gt(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) > SqrtRatio.unwrap(b);
}

function ge(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) >= SqrtRatio.unwrap(b);
}

function eq(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) == SqrtRatio.unwrap(b);
}

function neq(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) != SqrtRatio.unwrap(b);
}

function sub(SqrtRatio a, SqrtRatio b) pure returns (uint256) {
    return a.toFixed() - b.toFixed();
}
