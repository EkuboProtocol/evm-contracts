// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolConfig} from "./poolConfig.sol";

/// @notice token0 (high 160 bits) and extension-free pool config (low 96 bits).
/// @dev Callers must validate that config.extension() is zero before packing.
type FreeLPPool is bytes32;

/// @notice token1 (high 160 bits), 32 reserved zero bits, lower tick (32 bits), upper tick (32 bits).
type FreeLPRange is bytes32;

using {token0, config} for FreeLPPool global;
using {token1, tickLower, tickUpper} for FreeLPRange global;

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

function createFreeLPRange(address token, int32 lower, int32 upper) pure returns (FreeLPRange v) {
    assembly ("memory-safe") {
        v := or(shl(96, token), or(shl(32, and(lower, 0xffffffff)), and(upper, 0xffffffff)))
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
