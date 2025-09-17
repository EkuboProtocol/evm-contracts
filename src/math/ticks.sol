// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {MAX_TICK_MAGNITUDE} from "./constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
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

/// @notice Converts a sqrt price ratio to its corresponding tick
/// @dev Uses logarithmic calculation to find the tick that most closely represents the sqrt ratio
/// @param sqrtRatio The sqrt price ratio to convert
/// @return The tick corresponding to the sqrt ratio (rounded down)
function sqrtRatioToTick(SqrtRatio sqrtRatio) pure returns (int32) {
    unchecked {
        uint256 sqrtRatioFixed = sqrtRatio.toFixed();

        bool negative = (sqrtRatioFixed >> 128) == 0;

        uint256 x = negative ? (type(uint256).max / sqrtRatioFixed) : sqrtRatioFixed;

        // we know x >> 128 is never zero because we check bounds above and then reciprocate sqrtRatio if the high 128 bits are zero
        // so we don't need to handle the exceptional case of log2(0)
        uint256 msbHigh = FixedPointMathLib.log2(x >> 128);
        x = x >> (msbHigh + 1);
        uint256 log2Unsigned = msbHigh * 0x10000000000000000;

        assembly ("memory-safe") {
            // 63
            x := shr(127, mul(x, x))
            let is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x8000000000000000))
            x := shr(is_high_nonzero, x)

            // 62
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x4000000000000000))
            x := shr(is_high_nonzero, x)

            // 61
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x2000000000000000))
            x := shr(is_high_nonzero, x)

            // 60
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x1000000000000000))
            x := shr(is_high_nonzero, x)

            // 59
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x800000000000000))
            x := shr(is_high_nonzero, x)

            // 58
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x400000000000000))
            x := shr(is_high_nonzero, x)

            // 57
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x200000000000000))
            x := shr(is_high_nonzero, x)

            // 56
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x100000000000000))
            x := shr(is_high_nonzero, x)

            // 55
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x80000000000000))
            x := shr(is_high_nonzero, x)

            // 54
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x40000000000000))
            x := shr(is_high_nonzero, x)

            // 53
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x20000000000000))
            x := shr(is_high_nonzero, x)

            // 52
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x10000000000000))
            x := shr(is_high_nonzero, x)

            // 51
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x8000000000000))
            x := shr(is_high_nonzero, x)

            // 50
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x4000000000000))
            x := shr(is_high_nonzero, x)

            // 49
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x2000000000000))
            x := shr(is_high_nonzero, x)

            // 48
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x1000000000000))
            x := shr(is_high_nonzero, x)

            // 47
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x800000000000))
            x := shr(is_high_nonzero, x)

            // 46
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x400000000000))
            x := shr(is_high_nonzero, x)

            // 45
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x200000000000))
            x := shr(is_high_nonzero, x)

            // 44
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x100000000000))
            x := shr(is_high_nonzero, x)

            // 43
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x80000000000))
            x := shr(is_high_nonzero, x)

            // 42
            x := shr(127, mul(x, x))
            is_high_nonzero := eq(iszero(shr(128, x)), 0)
            log2Unsigned := add(log2Unsigned, mul(is_high_nonzero, 0x40000000000))
        }

        // 25572630076711825471857579 == 2**64/(log base 2 of sqrt tick size)
        // https://www.wolframalpha.com/input?i=floor%28%281%2F+log+base+2+of+%28sqrt%281.000001%29%29%29*2**64%29
        int256 logBaseTickSizeX128 =
            (negative ? -int256(log2Unsigned) : int256(log2Unsigned)) * 25572630076711825471857579;

        int32 tickLow;
        int32 tickHigh;

        if (negative) {
            tickLow = int32((logBaseTickSizeX128 - 112469616488610087266845472033458199637) >> 128);
            tickHigh = int32((logBaseTickSizeX128) >> 128);
        } else {
            tickLow = int32((logBaseTickSizeX128) >> 128);
            tickHigh = int32((logBaseTickSizeX128 + 112469616488610087266845472033458199637) >> 128);
        }

        if (tickLow == tickHigh) {
            return tickLow;
        }

        if (tickToSqrtRatio(tickHigh) <= sqrtRatio) return tickHigh;

        return tickLow;
    }
}
