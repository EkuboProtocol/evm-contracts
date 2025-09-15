// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";

using {toPositionId} for PositionKey global;
using {validateBounds} for Bounds global;

// Bounds are lower and upper prices for which a position is active
struct Bounds {
    int32 lower;
    int32 upper;
}

error BoundsOrder();
error MinMaxBounds();
error BoundsTickSpacing();
error FullRangeOnlyPool();

function validateBounds(Bounds memory bounds, uint32 tickSpacing) pure {
    if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) {
        if (bounds.lower != MIN_TICK || bounds.upper != MAX_TICK) revert FullRangeOnlyPool();
    } else {
        if (bounds.lower >= bounds.upper) revert BoundsOrder();
        if (bounds.lower < MIN_TICK || bounds.upper > MAX_TICK) revert MinMaxBounds();
        int32 spacing = int32(tickSpacing);
        if (bounds.lower % spacing != 0 || bounds.upper % spacing != 0) revert BoundsTickSpacing();
    }
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
