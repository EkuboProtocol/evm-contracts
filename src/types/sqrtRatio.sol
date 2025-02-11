// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// A dynamic fixed point number that stores a shifting 94 bit view of the underlying fixed point value
// If the most significant 2 bits are 11, it represents a 64.30
// If the most significant 2 bits are 10, it represents a 32.62 number
// If the most significant 2 bits are 01, it represents a 0.94 number
// If the most significant 2 bits are 00, it represents a 0.126 number that is always less than 2**-32

type SqrtRatio is uint96;

SqrtRatio constant MIN_SQRT_RATIO = SqrtRatio.wrap(4611797791050542631);
SqrtRatio constant MAX_SQRT_RATIO = SqrtRatio.wrap(79227682466138141934206691491);
SqrtRatio constant ONE = SqrtRatio.wrap((1 << 95) + (1 << 62));

using {toFixed, isValid, ge as >=, le as <=, lt as <, gt as >, eq as ==, neq as !=, sub} for SqrtRatio global;

error ValueOverflowsSqrtRatioContainer();

uint96 constant TWO_POW_95 = uint96(1) << 95;
uint96 constant TWO_POW_94 = uint96(1) << 94;

function isValid(SqrtRatio sqrtRatio) pure returns (bool) {
    uint96 v = SqrtRatio.unwrap(sqrtRatio);
    bool p = v & TWO_POW_95 != 0;
    bool pp = v & TWO_POW_94 != 0;

    if (p) {
        if (pp) {
            return (v - TWO_POW_95 - TWO_POW_94) >= (1 << 62) && v <= SqrtRatio.unwrap(MAX_SQRT_RATIO);
        } else {
            return (v - TWO_POW_95) >= (1 << 62);
        }
    } else {
        if (pp) {
            return (v - TWO_POW_94) >= (1 << 62);
        } else {
            return v >= SqrtRatio.unwrap(MIN_SQRT_RATIO);
        }
    }
}

// Converts a 64.128 value into the compact SqrtRatio representation
function toSqrtRatio(uint256 sqrtRatio, bool roundUp) pure returns (SqrtRatio) {
    unchecked {
        if (sqrtRatio > type(uint160).max) {
            if (sqrtRatio > type(uint192).max) revert ValueOverflowsSqrtRatioContainer();
            return roundUp
                ? SqrtRatio.wrap(uint96(TWO_POW_95 | TWO_POW_94 | ((sqrtRatio + 0x3ffffffffffffffffffffffff) >> 98)))
                : SqrtRatio.wrap(uint96(TWO_POW_95 | TWO_POW_94 | (sqrtRatio >> 98)));
        } else if (sqrtRatio > type(uint128).max) {
            return roundUp
                ? toSqrtRatio(sqrtRatio + 0x3ffffffffffffffff, false)
                : SqrtRatio.wrap(uint96(TWO_POW_95 | (sqrtRatio >> 66)));
        } else if (sqrtRatio > type(uint96).max) {
            return roundUp
                ? toSqrtRatio(sqrtRatio + 0x3ffffffff, false)
                : SqrtRatio.wrap(TWO_POW_94 | uint96((sqrtRatio >> 34)));
        } else {
            return roundUp ? toSqrtRatio(sqrtRatio + 0x3, false) : SqrtRatio.wrap(uint96((sqrtRatio >> 2)));
        }
    }
}

error InvalidSqrtRatioToFixed();

// Returns a 64.128 value for the given sqrt ratio
function toFixed(SqrtRatio sqrtRatio) pure returns (uint256) {
    unchecked {
        uint128 value = SqrtRatio.unwrap(sqrtRatio);
        if (value & TWO_POW_95 != 0) {
            if (value & TWO_POW_94 != 0) {
                return uint256(value - TWO_POW_95 - TWO_POW_94) << 98;
            } else {
                return uint256(value - TWO_POW_95) << 66;
            }
        } else {
            if (value & TWO_POW_94 != 0) {
                return uint256(value - TWO_POW_94) << 34;
            } else {
                return uint256(value) << 2;
            }
        }
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
