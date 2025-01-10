// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

error MsbNonZero();

function msb(uint256 x) pure returns (uint8) {
    if (x > type(uint128).max) {
        return 128 + msb128(uint128(x >> 128));
    } else {
        return msb128(uint128(x));
    }
}

function msb128(uint128 x) pure returns (uint8) {
    if (x == 0) revert MsbNonZero();

    uint8 res = 0;
    unchecked {
        if (x >= 0x10000000000000000) {
            x >>= 64;
            res += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            res += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            res += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            res += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            res += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            res += 2;
        }
        if (x >= 0x2) {
            res += 1;
        }
    }
    return res;
}
