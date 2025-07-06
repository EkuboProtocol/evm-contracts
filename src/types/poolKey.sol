// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MAX_TICK_SPACING, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";

using {toPoolId, validatePoolKey, isFullRange, mustLoadFees, tickSpacing, fee, extension} for PoolKey global;

// address (20 bytes) | fee (8 bytes) | tickSpacing (4 bytes)
type Config is bytes32;

function tickSpacing(PoolKey memory pk) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(mload(add(64, pk)), 0xffffffff)
    }
}

function fee(PoolKey memory pk) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(mload(add(60, pk)), 0xffffffffffffffff)
    }
}

function extension(PoolKey memory pk) pure returns (address r) {
    assembly ("memory-safe") {
        r := and(mload(add(52, pk)), 0xffffffffffffffffffffffffffffffffffffffff)
    }
}

function mustLoadFees(PoolKey memory pk) pure returns (bool r) {
    assembly ("memory-safe") {
        // only if either of tick spacing and fee are nonzero
        // if _both_ are zero, then we know we do not need to load fees for swaps
        r := iszero(iszero(and(mload(add(64, pk)), 0xffffffffffffffffffffffff)))
    }
}

function isFullRange(PoolKey memory pk) pure returns (bool r) {
    r = pk.tickSpacing() == FULL_RANGE_ONLY_TICK_SPACING;
}

function toConfig(uint64 _fee, uint32 _tickSpacing, address _extension) pure returns (Config c) {
    assembly ("memory-safe") {
        c := add(add(shl(96, _extension), shl(32, _fee)), _tickSpacing)
    }
}

// Each pool has its own state associated with this key
struct PoolKey {
    address token0;
    address token1;
    Config config;
}

error TokensMustBeSorted();
error InvalidTickSpacing();

function validatePoolKey(PoolKey memory key) pure {
    if (key.token0 >= key.token1) revert TokensMustBeSorted();
    if (key.tickSpacing() > MAX_TICK_SPACING) {
        revert InvalidTickSpacing();
    }
}

function toPoolId(PoolKey memory key) pure returns (bytes16 result) {
    assembly ("memory-safe") {
        // it's already copied into memory
        result := shl(128, keccak256(key, 96))
    }
}
