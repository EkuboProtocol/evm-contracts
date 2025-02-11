// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// A dynamic fixed point number (a la floating point) that stores a shifting 94 bit view of the underlying fixed point value,
//  based on the most significant bits (mantissa)
// If the most significant 2 bits are 11, it represents a 64.30
// If the most significant 2 bits are 10, it represents a 32.62 number
// If the most significant 2 bits are 01, it represents a 0.94 number
// If the most significant 2 bits are 00, it represents a 0.126 number that is always less than 2**-32

type SqrtRatio is uint96;

uint96 constant MIN_SQRT_RATIO_RAW = 4611797791050542631;
SqrtRatio constant MIN_SQRT_RATIO = SqrtRatio.wrap(MIN_SQRT_RATIO_RAW);
uint96 constant MAX_SQRT_RATIO_RAW = 79227682466138141934206691491;
SqrtRatio constant MAX_SQRT_RATIO = SqrtRatio.wrap(MAX_SQRT_RATIO_RAW);

uint96 constant TWO_POW_95 = 0x800000000000000000000000;
uint96 constant TWO_POW_94 = 0x400000000000000000000000;

SqrtRatio constant ONE = SqrtRatio.wrap((TWO_POW_95) + (1 << 62));

using {toFixed, isValid, ge as >=, le as <=, lt as <, gt as >, eq as ==, neq as !=} for SqrtRatio global;

function isValid(SqrtRatio sqrtRatio) pure returns (bool r) {
    assembly ("memory-safe") {
        r :=
            and(
                and(
                    iszero(lt(and(sqrtRatio, 0x3fffffffffffffffffffffff), 0x4000000000000000)),
                    iszero(gt(sqrtRatio, MAX_SQRT_RATIO_RAW))
                ),
                iszero(lt(sqrtRatio, MIN_SQRT_RATIO_RAW))
            )
    }
}

error ValueOverflowsSqrtRatioContainer();

// Converts a 64.128 value into the compact SqrtRatio representation
function toSqrtRatio(uint256 sqrtRatio, bool roundUp) pure returns (SqrtRatio r) {
    unchecked {
        if (sqrtRatio > type(uint192).max) {
            revert ValueOverflowsSqrtRatioContainer();
        } else if (sqrtRatio > type(uint160).max) {
            return roundUp
                ? toSqrtRatio(sqrtRatio + 0x3ffffffffffffffffffffffff, false)
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

// Returns the 64.128 representation of the given sqrt ratio
function toFixed(SqrtRatio sqrtRatio) pure returns (uint256 r) {
    assembly ("memory-safe") {
        let bitshift :=
            add(
                2,
                add(
                    mul(iszero(iszero(and(sqrtRatio, TWO_POW_95))), 64), mul(iszero(iszero(and(sqrtRatio, TWO_POW_94))), 32)
                )
            )
        r := shl(bitshift, and(sqrtRatio, 0x3fffffffffffffffffffffff))
    }
}

// The below operators assume that the SqrtRatio is valid, i.e. SqrtRatio#isValid returns true

function lt(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) < SqrtRatio.unwrap(b);
}

function gt(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) > SqrtRatio.unwrap(b);
}

function le(SqrtRatio a, SqrtRatio b) pure returns (bool r) {
    r = SqrtRatio.unwrap(a) <= SqrtRatio.unwrap(b);
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
