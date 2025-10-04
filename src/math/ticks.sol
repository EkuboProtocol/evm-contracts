// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MAX_TICK_MAGNITUDE} from "./constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {SqrtRatio, toSqrtRatio} from "../types/sqrtRatio.sol";

// Tick Math Library
// Contains functions for converting between ticks and sqrt price ratios
// Ticks represent discrete price points, while sqrt ratios represent the actual prices
// The relationship is: sqrtRatio = sqrt(1.000001^tick)

/// @notice Thrown when a tick value is outside the valid range
/// @param tick The invalid tick value
error InvalidTick(int32 tick);

/// @notice Converts a tick to its corresponding sqrt price ratio
/// @dev Uses bit manipulation and precomputed constants for gas efficiency
/// @dev Optimized to only multiply for set bits using CTZ-based indexing
/// @param tick The tick to convert (must be within MIN_TICK and MAX_TICK)
/// @return r The sqrt price ratio corresponding to the tick
function tickToSqrtRatio(int32 tick) pure returns (SqrtRatio r) {
    unchecked {
        uint256 t = FixedPointMathLib.abs(tick);
        if (t > MAX_TICK_MAGNITUDE) revert InvalidTick(tick);

        uint256 ratio;
        assembly ("memory-safe") {
            // bit 0 is handled with a single conditional subtract from 2^128
            ratio := sub(0x100000000000000000000000000000000, mul(and(t, 0x1), 0x8637b66cd638344daef276cd7c5))

            // Table of constants for bits 1-26 (indexed by bit position)
            // Each constant represents sqrt(1.000001^(2^i)) in Q128 format
            function tableLoad(idx) -> c {
                switch idx
                case 1 { c := 0xffffef390978c398134b4ff3764fe410 }
                case 2 { c := 0xffffde72140b00a354bd3dc828e976c9 }
                case 3 { c := 0xffffbce42c7be6c998ad6318193c0b18 }
                case 4 { c := 0xffff79c86a8f6150a32d9778eceef97c }
                case 5 { c := 0xfffef3911b7cff24ba1b3dbb5f8f5974 }
                case 6 { c := 0xfffde72350725cc4ea8feece3b5f13c8 }
                case 7 { c := 0xfffbce4b06c196e9247ac87695d53c60 }
                case 8 { c := 0xfff79ca7a4d1bf1ee8556cea23cdbaa5 }
                case 9 { c := 0xffef3995a5b6a6267530f207142a5764 }
                case 10 { c := 0xffde7444b28145508125d10077ba83b8 }
                case 11 { c := 0xffbceceeb791747f10df216f2e53ec57 }
                case 12 { c := 0xff79eb706b9a64c6431d76e63531e929 }
                case 13 { c := 0xfef41d1a5f2ae3a20676bec6f7f9459a }
                case 14 { c := 0xfde95287d26d81bea159c37073122c73 }
                case 15 { c := 0xfbd701c7cbc4c8a6bb81efd232d1e4e7 }
                case 16 { c := 0xf7bf5211c72f5185f372aeb1d48f937e }
                case 17 { c := 0xefc2bf59df33ecc28125cf78ec4f167f }
                case 18 { c := 0xe08d35706200796273f0b3a981d90cfd }
                case 19 { c := 0xc4f76b68947482dc198a48a54348c4ed }
                case 20 { c := 0x978bcb9894317807e5fa4498eee7c0fa }
                case 21 { c := 0x59b63684b86e9f486ec54727371ba6ca }
                case 22 { c := 0x1f703399d88f6aa83a28b22d4a1f56e3 }
                case 23 { c := 0x3dc5dac7376e20fc8679758d1bcdcfc }
                case 24 { c := 0xee7e32d61fdb0a5e622b820f681d0 }
                case 25 { c := 0xde2ee4bc381afa7089aa84bb66 }
                case 26 { c := 0xc0d55d4d7152c25fb139 }
            }

            // Count trailing zeros for a single isolated bit
            // After shifting t right by 1, bits are at positions 0-25
            function ctz(x) -> n {
                // For a single bit, we can find its position by checking against powers of 2
                switch x
                case 0x1 { n := 0 }
                case 0x2 { n := 1 }
                case 0x4 { n := 2 }
                case 0x8 { n := 3 }
                case 0x10 { n := 4 }
                case 0x20 { n := 5 }
                case 0x40 { n := 6 }
                case 0x80 { n := 7 }
                case 0x100 { n := 8 }
                case 0x200 { n := 9 }
                case 0x400 { n := 10 }
                case 0x800 { n := 11 }
                case 0x1000 { n := 12 }
                case 0x2000 { n := 13 }
                case 0x4000 { n := 14 }
                case 0x8000 { n := 15 }
                case 0x10000 { n := 16 }
                case 0x20000 { n := 17 }
                case 0x40000 { n := 18 }
                case 0x80000 { n := 19 }
                case 0x100000 { n := 20 }
                case 0x200000 { n := 21 }
                case 0x400000 { n := 22 }
                case 0x800000 { n := 23 }
                case 0x1000000 { n := 24 }
                case 0x2000000 { n := 25 }
            }

            // Multiply and shift right by 128 bits
            function mulShift128(a, c) -> z {
                z := shr(128, mul(a, c))
            }

            // Remove LSB (bit 0) which was already handled
            t := shr(1, t)

            // Process only set bits
            for {} t {} {
                let lsb := and(t, sub(0, t)) // Isolate least significant bit
                let idx := ctz(lsb) // Find bit position (0-25 after shift)
                let c := tableLoad(add(idx, 1)) // Load constant (table is indexed 1-26)
                ratio := mulShift128(ratio, c) // Multiply and shift
                t := sub(t, lsb) // Clear the processed bit
            }

            // If original tick > 0, invert: ratio = maxUint / ratio
            if sgt(tick, 0) { ratio := div(not(0), ratio) }
        }

        r = toSqrtRatio(ratio, false);
    }
}

uint256 constant ONE_Q127 = 1 << 127;

// Convert ln(m) series to log2(m):  log2(m) = (2 / ln 2) * s.
// Precompute K = round((2 / ln 2) * 2^64) as a uint (Q64 scalar).
// K = 53226052391377289966  (≈ 0x2e2a8eca5705fc2ee)
uint256 constant K_2_OVER_LN2_X64 = 53226052391377289966;

// 2^64 / log2(sqrt(1.000001)) for converting from log base 2 in X64 to log base tick
int256 constant INV_LB_X64 = 25572630076711825471857579;

// Error bounds of the tick computation based on the number of iterations ~= +-0.002 ticks
int256 constant ERROR_BOUNDS_X128 = int256((uint256(1) << 128) / 485);

/// @notice Converts a sqrt price ratio to its corresponding tick
/// @dev Computes log2 via one normalization + atanh series (no per-bit squaring loop)
/// @param sqrtRatio The valid sqrt price ratio to convert
/// @return tick The tick corresponding to the sqrt ratio
function sqrtRatioToTick(SqrtRatio sqrtRatio) pure returns (int32 tick) {
    unchecked {
        uint256 sqrtRatioFixed = sqrtRatio.toFixed();

        // Normalize sign via reciprocal if < 1. Keep this branch-free.
        bool negative;
        uint256 x;
        uint256 hi;
        assembly ("memory-safe") {
            negative := iszero(shr(128, sqrtRatioFixed))
            // x = negative ? (type(uint256).max / R) : R
            x := add(div(sub(0, negative), sqrtRatioFixed), mul(iszero(negative), sqrtRatioFixed))
            // We know (x >> 128) != 0 because we reciprocated sqrtRatioFixed
            hi := shr(128, x)
        }

        // Integer part of log2 via CLZ: floor(log2(hi)) = 255 - clz(hi)
        uint256 msbHigh;
        // todo: replace with clz opcode
        uint256 clz_hi = LibBit.clz(hi);
        assembly ("memory-safe") {
            msbHigh := sub(255, clz_hi)
        }

        // Reduce once so X ∈ [2^127, 2^128)  (Q1.127 mantissa)
        x = x >> (msbHigh + 1);

        // Fractional log2 using atanh on y = (m-1)/(m+1), m = X/2^127 ∈ [1,2)
        uint256 a = x - ONE_Q127; // (m - 1) * 2^127
        uint256 b = x + ONE_Q127; // (m + 1) * 2^127
        uint256 yQ = (a << 127) / b; // y in Q1.127

        // Build odd powers via y^2 ladder
        uint256 y2 = (yQ * yQ) >> 127; // y^2
        uint256 y3 = (yQ * y2) >> 127; // y^3
        uint256 y5 = (y3 * y2) >> 127; // y^5
        uint256 y7 = (y5 * y2) >> 127; // y^7
        uint256 y9 = (y7 * y2) >> 127; // y^9
        uint256 y11 = (y9 * y2) >> 127; // y^11
        uint256 y13 = (y11 * y2) >> 127; // y^13
        uint256 y15 = (y13 * y2) >> 127; // y^15

        // s = y + y^3/3 + y^5/5 + ... + y^15/15  (Q1.127)
        uint256 s = yQ + (y3 / 3) + (y5 / 5) + (y7 / 7) + (y9 / 9) + (y11 / 11) + (y13 / 13) + (y15 / 15);

        // fracX64 = ((2/ln2) * s) in Q64.64  =>  (s * K) >> 127
        uint256 fracX64 = (s * K_2_OVER_LN2_X64) >> 127;

        // Unsigned log2 in Q64.64
        uint256 log2Unsigned = (msbHigh << 64) + fracX64;

        // Map log2 to tick-space X128
        int256 base = negative ? -int256(log2Unsigned) : int256(log2Unsigned);

        int256 logBaseTickSizeX128 = base * INV_LB_X64;

        // Add error bounds to the computed logarithm
        int32 tickLow = int32((logBaseTickSizeX128 - ERROR_BOUNDS_X128) >> 128);
        tick = int32((logBaseTickSizeX128 + ERROR_BOUNDS_X128) >> 128);

        if (tick != tickLow) {
            // tickHigh overshoots
            if (tickToSqrtRatio(tick) > sqrtRatio) {
                tick = tickLow;
            }
        }
    }
}
