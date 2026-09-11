// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolConfig} from "./poolConfig.sol";

/// @notice token0 (high 160 bits) and pool type/fee config (low 96 bits).
type FreeLPPool is bytes32;

/// @notice token1 (high 160 bits), high 32 extension bits, lower tick (32 bits), upper tick (32 bits).
type FreeLPRange is bytes32;

using {token0, config, fullConfig} for FreeLPPool global;
using {token1, tickLower, tickUpper, extensionHigh} for FreeLPRange global;

function createFreeLPPool(address token, PoolConfig poolConfig) pure returns (FreeLPPool v) {
    assembly ("memory-safe") {
        v := or(shl(96, token), and(poolConfig, 0xffffffffffffffffffffffff))
    }
}

function token0(FreeLPPool v) pure returns (address token) {
    assembly ("memory-safe") { token := shr(96, v) }
}

function config(FreeLPPool v) pure returns (PoolConfig c) {
    assembly ("memory-safe") { c := and(v, 0xffffffffffffffffffffffff) }
}

function createFreeLPRange(address token, int32 lower, int32 upper, address extension) pure returns (FreeLPRange v) {
    assembly ("memory-safe") {
        v := or(
            or(shl(96, token), shl(64, shr(128, extension))),
            or(shl(32, and(lower, 0xffffffff)), and(upper, 0xffffffff))
        )
    }
}

function token1(FreeLPRange v) pure returns (address token) {
    assembly ("memory-safe") { token := shr(96, v) }
}

function tickLower(FreeLPRange v) pure returns (int32 tick) {
    assembly ("memory-safe") { tick := signextend(3, shr(32, v)) }
}

function tickUpper(FreeLPRange v) pure returns (int32 tick) {
    assembly ("memory-safe") { tick := signextend(3, v) }
}

function extensionHigh(FreeLPRange v) pure returns (uint32 high) {
    assembly ("memory-safe") { high := and(shr(64, v), 0xffffffff) }
}

function fullConfig(FreeLPPool pool, FreeLPRange range, uint128 extensionLow) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        c := or(
            and(pool, 0xffffffffffffffffffffffff),
            or(shl(96, extensionLow), shl(224, and(shr(64, range), 0xffffffff)))
        )
    }
}
