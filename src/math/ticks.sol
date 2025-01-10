// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {msb128} from "./bits.sol";

int32 constant MIN_TICK = -88722883;
int32 constant MAX_TICK = 88722883;
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);
uint32 constant MAX_TICK_SPACING = 354892;

error InvalidTick(int32 tick);

function tickToSqrtRatio(int32 tick) pure returns (uint256 ratio) {
    unchecked {
        uint32 t = tick < 0 ? uint32(-tick) : uint32(tick);
        if (t > MAX_TICK_MAGNITUDE) revert InvalidTick(tick);

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

// Returns the approximate 64.64 log2(x) value of x assuming x is a 128.128 fixed point number
function log2(uint256 x) pure returns (int128) {
    unchecked {
        bool negative;

        // x is less than 1x128, so we know the result is negative and compute the value of log2(1/x)
        if ((x >> 128) == 0) {
            x = (type(uint256).max / x);
            negative = true;
        }

        uint128 msbHigh = msb128(uint128(x >> 128));
        x = x >> (msbHigh + 1);
        uint128 result = msbHigh * 0x10000000000000000;

        // repeated halving steps => 63..42
        for (uint8 power = 63;; power--) {
            x = (x * x) >> 127;
            if ((x >> 128) != 0) {
                result += (uint128(1) << power);
                x >>= 1;
            }
            if (x == 0 || power == 42) break;
        }

        return negative ? -int128(result) : int128(result);
    }
}

uint256 constant MIN_SQRT_RATIO = 18446748437148339061;
uint256 constant MAX_SQRT_RATIO = 6277100250585753475930931601400621808602321654880405518632;

error InvalidSqrtRatio(uint256 sqrtRatio);

function sqrtRatioToTick(uint256 sqrtRatio) pure returns (int32) {
    unchecked {
        if (sqrtRatio >= MAX_SQRT_RATIO || sqrtRatio < MIN_SQRT_RATIO) {
            revert InvalidSqrtRatio(sqrtRatio);
        }

        int256 logBase2X64 = log2(sqrtRatio);

        // 25572630076711825471857579 == 2**64/(log base 2 of sqrt tick size)
        // https://www.wolframalpha.com/input?i=floor%28%281%2F+log+base+2+of+%28sqrt%281.000001%29%29%29*2**64%29
        int256 logBaseTickSizeX128 = int256(logBase2X64) * 25572630076711825471857579;

        int32 tickLow;
        int32 tickHigh;

        if (logBaseTickSizeX128 < 0) {
            tickLow = int32((logBaseTickSizeX128 - 112469616488610087266845472033458199637) >> 128);
            tickHigh = int32((logBaseTickSizeX128) >> 128);
        } else {
            tickLow = int32((logBaseTickSizeX128 - 1) >> 128);
            tickHigh = int32((logBaseTickSizeX128 + 112469616488610087266845472033458199637) >> 128);
        }

        if (tickLow == tickHigh) {
            return tickLow;
        }

        if (tickToSqrtRatio(tickHigh) <= sqrtRatio) return tickHigh;

        return tickLow;
    }
}
