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
/// @param tick The tick to convert (must be within MIN_TICK and MAX_TICK)
/// @return r The sqrt price ratio corresponding to the tick
function tickToSqrtRatio(int32 tick) pure returns (SqrtRatio r) {
    unchecked {
        uint256 t = FixedPointMathLib.abs(tick);
        if (t > MAX_TICK_MAGNITUDE) revert InvalidTick(tick);

        uint256 ratio;
        assembly ("memory-safe") {
            ratio := sub(0x100000000000000000000000000000000, mul(and(t, 0x1), 0x8637b66cd638344daef276cd7c5))
        }

        if ((t & 0x2) != 0) {
            ratio = (ratio * 0xffffef390978c398134b4ff3764fe410) >> 128;
        }
        if ((t & 0x4) != 0) {
            ratio = (ratio * 0xffffde72140b00a354bd3dc828e976c9) >> 128;
        }
        if ((t & 0x8) != 0) {
            ratio = (ratio * 0xffffbce42c7be6c998ad6318193c0b18) >> 128;
        }
        if ((t & 0x10) != 0) {
            ratio = (ratio * 0xffff79c86a8f6150a32d9778eceef97c) >> 128;
        }
        if ((t & 0x20) != 0) {
            ratio = (ratio * 0xfffef3911b7cff24ba1b3dbb5f8f5974) >> 128;
        }
        if ((t & 0x40) != 0) {
            ratio = (ratio * 0xfffde72350725cc4ea8feece3b5f13c8) >> 128;
        }
        if ((t & 0x80) != 0) {
            ratio = (ratio * 0xfffbce4b06c196e9247ac87695d53c60) >> 128;
        }
        if ((t & 0x100) != 0) {
            ratio = (ratio * 0xfff79ca7a4d1bf1ee8556cea23cdbaa5) >> 128;
        }
        if ((t & 0x200) != 0) {
            ratio = (ratio * 0xffef3995a5b6a6267530f207142a5764) >> 128;
        }
        if ((t & 0x400) != 0) {
            ratio = (ratio * 0xffde7444b28145508125d10077ba83b8) >> 128;
        }
        if ((t & 0x800) != 0) {
            ratio = (ratio * 0xffbceceeb791747f10df216f2e53ec57) >> 128;
        }
        if ((t & 0x1000) != 0) {
            ratio = (ratio * 0xff79eb706b9a64c6431d76e63531e929) >> 128;
        }
        if ((t & 0x2000) != 0) {
            ratio = (ratio * 0xfef41d1a5f2ae3a20676bec6f7f9459a) >> 128;
        }
        if ((t & 0x4000) != 0) {
            ratio = (ratio * 0xfde95287d26d81bea159c37073122c73) >> 128;
        }
        if ((t & 0x8000) != 0) {
            ratio = (ratio * 0xfbd701c7cbc4c8a6bb81efd232d1e4e7) >> 128;
        }
        if ((t & 0x10000) != 0) {
            ratio = (ratio * 0xf7bf5211c72f5185f372aeb1d48f937e) >> 128;
        }
        if ((t & 0x20000) != 0) {
            ratio = (ratio * 0xefc2bf59df33ecc28125cf78ec4f167f) >> 128;
        }
        if ((t & 0x40000) != 0) {
            ratio = (ratio * 0xe08d35706200796273f0b3a981d90cfd) >> 128;
        }
        if ((t & 0x80000) != 0) {
            ratio = (ratio * 0xc4f76b68947482dc198a48a54348c4ed) >> 128;
        }
        if ((t & 0x100000) != 0) {
            ratio = (ratio * 0x978bcb9894317807e5fa4498eee7c0fa) >> 128;
        }
        if ((t & 0x200000) != 0) {
            ratio = (ratio * 0x59b63684b86e9f486ec54727371ba6ca) >> 128;
        }
        if ((t & 0x400000) != 0) {
            ratio = (ratio * 0x1f703399d88f6aa83a28b22d4a1f56e3) >> 128;
        }
        if ((t & 0x800000) != 0) {
            ratio = (ratio * 0x3dc5dac7376e20fc8679758d1bcdcfc) >> 128;
        }
        if ((t & 0x1000000) != 0) {
            ratio = (ratio * 0xee7e32d61fdb0a5e622b820f681d0) >> 128;
        }
        if ((t & 0x2000000) != 0) {
            ratio = (ratio * 0xde2ee4bc381afa7089aa84bb66) >> 128;
        }
        if ((t & 0x4000000) != 0) {
            ratio = (ratio * 0xc0d55d4d7152c25fb139) >> 128;
        }

        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }

        r = toSqrtRatio(ratio, false);
    }
}

// F = 1.0 in Q1.127
uint256 constant F = 1 << 127;

// Convert ln(m) series to log2(m):  log2(m) = (2 / ln 2) * s.
// Precompute K = round((2 / ln 2) * 2^64) as a uint (Q64 scalar).
// K = 53226052391377289966  (≈ 0x2e2a8eca5705fc2ee)
uint256 constant K_2_OVER_LN2_X64 = 53226052391377289966;

/// @notice Converts a sqrt price ratio to its corresponding tick
/// @dev Computes log2 via one normalization + atanh series (no per-bit squaring loop)
/// @param sqrtRatio The valid sqrt price ratio to convert
/// @return The tick corresponding to the sqrt ratio (rounded down)

function sqrtRatioToTick(SqrtRatio sqrtRatio) pure returns (int32) {
    unchecked {
        uint256 R = sqrtRatio.toFixed();

        // If high 128 bits are zero, sqrtRatio < 1 → take reciprocal and mark negative.
        bool negative;
        uint256 x;
        assembly ("memory-safe") {
            negative := iszero(shr(128, R))
            // x = negative ? (type(uint256).max / R) : R
            x := add(div(sub(0, negative), R), mul(iszero(negative), R))
        }

        // We know (x >> 128) != 0 here.
        // Integer part: msbHigh = floor(log2(x >> 128)) using CLZ
        uint256 hi = x >> 128;
        uint256 hi_clz = LibBit.clz(hi);
        uint256 msbHigh;
        assembly ("memory-safe") {
            // Assume: clz(uint256) returns [0..256]; floor(log2(n)) = 255 - clz(n) for n>0
            msbHigh := sub(255, hi_clz)
        }

        // Normalize once so X ∈ [2^127, 2^128). This sets us up for a clean Q1.127 mantissa.
        x = x >> (msbHigh + 1);

        // --- Fractional log2 via atanh series on mantissa m = X / 2^127 ∈ [1, 2) ---
        // Let y = (m - 1) / (m + 1) ∈ [0, 1/3]; then:
        // ln(m) = 2 * (y + y^3/3 + y^5/5 + ... + y^(2n+1)/(2n+1)) + R_n
        // Using terms up to y^15 keeps |R_n| well below a half-tick in log2 units.
        // We compute everything in Q1.127 (implicit binary point at bit 127).

        // yQ = ((x - F) / (x + F)) in Q1.127  ->  ( (x-F) * F ) / (x+F)
        uint256 a = x - F;
        uint256 b = x + F;
        // (a << 127) cannot overflow: a < 2^128 ⇒ a<<127 < 2^255
        uint256 yQ = (a << 127) / b;

        // Powers of y: build y^2, then odd powers by multiplying by y^2 each time.
        uint256 y2 = (yQ * yQ) >> 127; // y^2
        uint256 y3 = (yQ * y2) >> 127; // y^3
        uint256 y5 = (y3 * y2) >> 127; // y^5
        uint256 y7 = (y5 * y2) >> 127; // y^7
        uint256 y9 = (y7 * y2) >> 127; // y^9
        uint256 y11 = (y9 * y2) >> 127; // y^11
        uint256 y13 = (y11 * y2) >> 127; // y^13
        uint256 y15 = (y13 * y2) >> 127; // y^15

        // s = y + y^3/3 + y^5/5 + ... + y^15/15  (still Q1.127)
        // DIV by tiny constants is cheap; using division here avoids storing reciprocals.
        uint256 s = yQ + (y3 / 3) + (y5 / 5) + (y7 / 7) + (y9 / 9) + (y11 / 11) + (y13 / 13) + (y15 / 15);

        // fracX64 = ((2/ln2) * s) in Q64.64  =>  (s * K) >> 127
        uint256 fracX64 = (s * K_2_OVER_LN2_X64) >> 127;

        // Compose full unsigned log2 in Q64.64: integer part | fractional part
        uint256 log2Unsigned = (msbHigh << 64) + fracX64;

        // Scale from log2 to "ticks" base: tick = log_{sqrt(1.000001)}(ratio)
        // This matches your previous constant/scaling (X128).
        // 25572630076711825471857579 == floor( 2^64 / log2(sqrt(1.000001)) )
        int256 logBaseTickSizeX128 =
            (negative ? -int256(log2Unsigned) : int256(log2Unsigned)) * 25572630076711825471857579;

        // Convert to candidate ticks (floor vs ceil) with your existing ±0.5 in X128 window.
        int32 tickLow;
        int32 tickHigh;

        if (negative) {
            // subtract 0.5 in X128 space before shifting for floor
            tickLow = int32((logBaseTickSizeX128 - 112469616488610087266845472033458199637) >> 128);
            tickHigh = int32((logBaseTickSizeX128) >> 128);
        } else {
            tickLow = int32((logBaseTickSizeX128) >> 128);
            // add 0.5 in X128 space for potential ceil
            tickHigh = int32((logBaseTickSizeX128 + 112469616488610087266845472033458199637) >> 128);
        }

        if (tickLow == tickHigh) return tickLow;

        // Final guard to fix any residual approximation error.
        if (tickToSqrtRatio(tickHigh) <= sqrtRatio) return tickHigh;
        return tickLow;
    }
}
