// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../math/ticks.sol";

using {toPoolId, validatePoolKey} for PoolKey global;
using {toPositionId} for PositionKey global;
using {validateBounds} for Bounds global;

// Each pool has its own state associated with this key
struct PoolKey {
    address token0;
    address token1;
    uint128 fee;
    uint32 tickSpacing;
    address extension;
}

error InvalidTokens();
error InvalidTickSpacing();

function validatePoolKey(PoolKey memory key) pure {
    if (key.token0 == address(0) || key.token0 >= key.token1) revert InvalidTokens();
    if (key.tickSpacing == 0 || key.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
}

function toPoolId(PoolKey memory key) pure returns (bytes32 result) {
    assembly ("memory-safe") {
        // it's already copied into memory
        result := keccak256(key, 160)
    }
}

// Bounds are lower and upper prices for which a position is active
struct Bounds {
    int32 lower;
    int32 upper;
}

error BoundsOrder();
error MinMaxBounds();
error BoundsTickSpacing();

function validateBounds(Bounds memory bounds, uint32 tickSpacing) pure {
    if (bounds.lower >= bounds.upper) revert BoundsOrder();
    if (bounds.lower < MIN_TICK || bounds.upper > MAX_TICK) revert MinMaxBounds();
    int32 spacing = int32(tickSpacing);
    if (bounds.lower % spacing != 0 || bounds.upper % spacing != 0) revert BoundsTickSpacing();
}

function maxBounds(uint32 tickSpacing) pure returns (Bounds memory) {
    int32 spacing = int32(tickSpacing);

    return Bounds({lower: (MIN_TICK / spacing) * spacing, upper: (MAX_TICK / spacing) * spacing});
}

// A position is keyed by the pool and this position key
struct PositionKey {
    bytes32 salt;
    address owner;
    Bounds bounds;
}

function toPositionId(PositionKey memory key) pure returns (bytes32 result) {
    assembly ("memory-safe") {
        // salt and owner
        mstore(0, keccak256(key, 64))
        // bounds
        mstore(32, keccak256(mload(add(key, 64)), 64))

        result := keccak256(0, 64)
    }
}
