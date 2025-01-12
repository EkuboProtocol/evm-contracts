// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../math/ticks.sol";

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
    if (key.token0 == address(0) || key.token0 > key.token1) revert InvalidTokens();
    if (key.tickSpacing == 0 || key.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
}

// Bounds are lower and upper prices for which a position is active
struct Bounds {
    int128 lower;
    int128 upper;
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

// A position is keyed by the pool and this position key
struct PositionKey {
    bytes32 salt;
    address owner;
    Bounds bounds;
}

// Contracts can save and load balances in core by this key
struct SavedBalanceKey {
    address owner;
    address token;
    bytes32 salt;
}
