// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

struct PoolPrice {
    // the current ratio, up to 192 bits
    uint192 sqrt_ratio;
    // the current tick, up to 32 bits
    int32 tick;
}
