// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

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
uint96 constant TWO_POW_62 = 0x4000000000000000;
uint96 constant TWO_POW_62_MINUS_ONE = 0x3fffffffffffffff;
uint96 constant BIT_MASK = 0xc00000000000000000000000; // TWO_POW_95 | TWO_POW_94

SqrtRatio constant ONE = SqrtRatio.wrap((TWO_POW_95) + (1 << 62));

using {
    toFixed,
    isValid,
    ge as >=,
    le as <=,
    lt as <,
    gt as >,
    eq as ==,
    neq as !=,
    isZero,
    min,
    max
} for SqrtRatio global;

function isValid(SqrtRatio sqrtRatio) pure returns (bool r) {
    assembly ("memory-safe") {
        r :=
            and(
                // greater than or equal to TWO_POW_62, i.e. the whole number portion is nonzero
                gt(and(sqrtRatio, not(BIT_MASK)), TWO_POW_62_MINUS_ONE),
                // and between min/max sqrt ratio
                and(iszero(lt(sqrtRatio, MIN_SQRT_RATIO_RAW)), iszero(gt(sqrtRatio, MAX_SQRT_RATIO_RAW)))
            )
    }
}

error ValueOverflowsSqrtRatioContainer();

// If passing a value greater than this constant with roundUp = true, toSqrtRatio will overflow
// For roundUp = false, the constant is type(uint192).max
uint256 constant MAX_FIXED_VALUE_ROUND_UP =
    0x1000000000000000000000000000000000000000000000000 - 0x4000000000000000000000000;

// Converts a 64.128 value into the compact SqrtRatio representation
function toSqrtRatio(uint256 sqrtRatio, bool roundUp) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        let addend := mul(roundUp, 0x3)

        // lt 2**96 after rounding up
        switch lt(sqrtRatio, sub(0x1000000000000000000000000, addend))
        case 1 { r := shr(2, add(sqrtRatio, addend)) }
        default {
            // 2**34 - 1
            addend := mul(roundUp, 0x3ffffffff)
            // lt 2**128 after rounding up
            switch lt(sqrtRatio, sub(0x100000000000000000000000000000000, addend))
            case 1 { r := or(TWO_POW_94, shr(34, add(sqrtRatio, addend))) }
            default {
                addend := mul(roundUp, 0x3ffffffffffffffff)
                // lt 2**160 after rounding up
                switch lt(sqrtRatio, sub(0x10000000000000000000000000000000000000000, addend))
                case 1 { r := or(TWO_POW_95, shr(66, add(sqrtRatio, addend))) }
                default {
                    // 2**98 - 1
                    addend := mul(roundUp, 0x3ffffffffffffffffffffffff)
                    switch lt(sqrtRatio, sub(0x1000000000000000000000000000000000000000000000000, addend))
                    case 1 { r := or(BIT_MASK, shr(98, add(sqrtRatio, addend))) }
                    default {
                        // cast sig "ValueOverflowsSqrtRatioContainer()"
                        mstore(0, shl(224, 0xa10459f4))
                        revert(0, 4)
                    }
                }
            }
        }
    }
}

// Returns the 64.128 representation of the given sqrt ratio
function toFixed(SqrtRatio sqrtRatio) pure returns (uint256 r) {
    assembly ("memory-safe") {
        r := shl(add(2, shr(89, and(sqrtRatio, BIT_MASK))), and(sqrtRatio, not(BIT_MASK)))
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

function isZero(SqrtRatio a) pure returns (bool r) {
    assembly ("memory-safe") {
        r := iszero(a)
    }
}

function max(SqrtRatio a, SqrtRatio b) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        r := xor(a, mul(xor(a, b), gt(b, a)))
    }
}

function min(SqrtRatio a, SqrtRatio b) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        r := xor(a, mul(xor(a, b), lt(b, a)))
    }
}
