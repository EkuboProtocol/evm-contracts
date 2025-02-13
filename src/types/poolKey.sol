// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MAX_TICK_SPACING} from "../math/constants.sol";

using {toPoolId, validatePoolKey} for PoolKey global;

// address (20 bytes) | fee (8 bytes) | tickSpacing (4 bytes)
type Config is bytes32;

using {mustLoadFees, tickSpacing, fee, extension} for Config global;

function tickSpacing(Config c) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(c, 0xffffffff)
    }
}

function fee(Config c) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(32, c), 0xffffffffffffffff)
    }
}

function extension(Config c) pure returns (address r) {
    assembly ("memory-safe") {
        r := shr(96, c)
    }
}

function mustLoadFees(Config c) pure returns (bool r) {
    assembly ("memory-safe") {
        // only if either of tick spacing and fee are nonzero
        // if _both_ are zero, then we know we do not need to load fees for swaps
        r := iszero(iszero(and(c, 0xffffffffffffffffffffffffffffffff)))
    }
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
    if (key.config.tickSpacing() > MAX_TICK_SPACING) {
        revert InvalidTickSpacing();
    }
}

function toPoolId(PoolKey memory key) pure returns (bytes32 result) {
    assembly ("memory-safe") {
        // it's already copied into memory
        result := keccak256(key, 96)
    }
}
