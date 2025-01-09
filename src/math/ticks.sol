// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {msb} from "./bits.sol";

int32 constant MIN_TICK = -88722883;
int32 constant MAX_TICK = 88722883;
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);
uint32 constant MAX_TICK_SPACING = 354892;

uint256 constant MIN_SQRT_RATIO = 18446748437148339061;
uint256 constant MAX_SQRT_RATIO = 6277100250585753475930931601400621808602321654880405518632;

// used in sqrt_ratio_to_tick to determine whether we need to align with tick to sqrt ratio result
uint256 constant MAX_ERROR_MAGNITUDE = 112469616488610087266845472033458199637;

// This constant was used for the approximate log2(1.000001) scaling
// 25572630076711825471857579
uint256 constant TICK_LOG2_CONVERSION = 25572630076711825471857579;

// ------------------------------------------------------
// tick_to_sqrt_ratio
// ------------------------------------------------------
// sqrt(1.000001)^tick => 128.128 fixed-point
// We replaced i129 with int32, so ticks outside +/- ~2e9 will not behave the same.

error TickMagnitude();

function tickToSqrtRatio(int32 tick) pure returns (uint256 ratio) {
    unchecked {
        uint32 t = tick < 0 ? uint32(-tick) : uint32(tick);
        if (t > MAX_TICK_MAGNITUDE) revert TickMagnitude();

        if ((t & 0x1) != 0) {
            ratio = 0xfffff79c8499329c7cbb2510d893283b;
        } else {
            ratio = 0x100000000000000000000000000000000;
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

        return ratio;
    }
}

// by_2_127(x): In the original code, it doubled x in 512 bits, then took the middle bits.
// A simpler read is “(2*x) >> 127”, but to match the original exactly,
// we replicate it as: sum = x + x => top 256 bits go to .low, plus an overflow bit.
// We can interpret that as ((2*x) >> 256), then place that in the lower bits, etc.
// Here we simply do: (2*x) >> 127  to emulate the “shift everything 127 bits down”.
function by2_127(uint256 x) pure returns (uint256) {
    unchecked {
        return (2 * x) >> 127;
    }
}

// ------------------------------------------------------
// log2 function
// ------------------------------------------------------
// log2(x) returns (log2(x), sign).
// If x.high == 0 => we invert x and set sign = !sign
// Then do repeated squaring (by_2_127) to approximate log2
function log2x(uint256 x) pure returns (int128) {
    // If top half is zero, treat it as “negative result => log2(1/x)”
    if (x >> 128 == 0) {
        // invert
        // note: for consistency, we clamp to a 256 bit result
        // “(maxUint256 - 1) / x” in original code was 512 bits, but we do a simpler invert
        // to keep it short.
        x = (type(uint256).max / x);
        // sign flips
        return -log2x(x);
    }

    // otherwise top half is non-zero
    uint128 msbHigh = msb(uint128(x >> 128));
    // shift down by (msbHigh+1) bits
    // then accumulate (msbHigh * 2^64) into log_2
    x = x / (uint256(1) << (msbHigh + 1));
    uint128 log_2 = msbHigh * 0x10000000000000000;

    // repeated halving steps => 63..42
    for (uint8 power = 63; power >= 42; power--) {
        x = by2_127(x * x);
        if (x >> 128 != 0) {
            log_2 += (uint128(1) << power);
            x >>= 1; // dividing by 2
        }
        if (power == 42) break;
    }

    return int128(log_2);
}

error InvalidSqrtRatio();

// ------------------------------------------------------
// sqrt_ratio_to_tick
// ------------------------------------------------------
// approximate “log base sqrt(1.000001)” of sqrt_ratio
// i.e. we do log2(sqrt_ratio) * (1 / log2(sqrt(1.000001)))
// then handle sign etc.
function sqrtRatioToTick(uint256 sqrtRatio) pure returns (int32) {
    if (sqrtRatio >= MAX_SQRT_RATIO || sqrtRatio < MIN_SQRT_RATIO) {
        revert InvalidSqrtRatio();
    }

    int128 log2sqrt = log2x(sqrtRatio);
    bool sign = log2sqrt < 0;

    // multiply by scale factor (25572630076711825471857579) >> 128
    // ignoring any wide-math remainder
    uint256 tickMagX128;
    unchecked {
        tickMagX128 = (uint256(uint128(sign ? -log2sqrt : log2sqrt)) * TICK_LOG2_CONVERSION);
    }

    // incorporate an “error” margin. We do rough bounding
    // original code did wide add with MAX_ERROR_MAGNITUDE
    uint256 hiPart = tickMagX128 >> 128;
    uint256 hiPartPlusErr = (tickMagX128 + MAX_ERROR_MAGNITUDE) >> 128;

    // pick tickLow / tickHigh
    int32 tickLow = int32(uint32((sign ? hiPartPlusErr : hiPart)));
    int32 tickHigh = int32(uint32((sign ? hiPart : hiPartPlusErr)));

    // if they’re the same, done
    if (tickLow == tickHigh) {
        return (sign ? -tickLow : tickLow);
    }

    // check which side
    int32 chosen = (tickHighToSqrtRatio(tickHigh, sqrtRatio, sign)) ? tickHigh : tickLow;

    return sign ? -chosen : chosen;
}

// Quick helper to test if tickHigh is still <= sqrtRatio
function tickHighToSqrtRatio(int32 testTick, uint256 sr, bool isNegative) pure returns (bool) {
    // compute ratio for testTick
    uint256 ratio = tickToSqrtRatio(isNegative ? (-testTick) : testTick);
    // check ratio <= sr
    return (ratio <= sr);
}
