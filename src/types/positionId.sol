// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {PoolConfig} from "./poolConfig.sol";

type PositionId is bytes32;

using {validateBounds, salt, tickLower, tickUpper} for PositionId global;

function salt(PositionId positionId) pure returns (bytes24 v) {
    assembly ("memory-safe") {
        v := shl(64, shr(64, positionId))
    }
}

function tickLower(PositionId positionId) pure returns (int32 v) {
    assembly ("memory-safe") {
        // shift down, then signextend to 32 bits
        v := signextend(3, shr(32, positionId))
    }
}

function tickUpper(PositionId positionId) pure returns (int32 v) {
    assembly ("memory-safe") {
        // lowest 4 bytes, then signextend to 32 bits
        v := signextend(3, positionId)
    }
}

function createPositionId(bytes24 _salt, int32 _tickLower, int32 _tickUpper) pure returns (PositionId v) {
    assembly ("memory-safe") {
        // v = salt | (tickLower << 32) | tickUpper
        v := or(shl(64, shr(64, _salt)), or(shl(32, and(_tickLower, 0xFFFFFFFF)), and(_tickUpper, 0xFFFFFFFF)))
    }
}

/// @notice Thrown when the order of the position bounds is invalid, i.e. tickLower >= tickUpper
error BoundsOrder();
/// @notice Thrown when the bounds of the position are greater than or less than the min/max tick
error MinMaxBounds();
/// @notice Thrown when the ticks of the bounds do not align with tick spacing, i.e. tick{Lower,Upper} % tickSpacing != 0
error BoundsTickSpacing();
/// @notice Thrown if the pool is full range only and the position is not full range
error FullRangeOnlyPool();

function validateBounds(PositionId positionId, PoolConfig config) pure {
    if (config.isFullRange()) {
        if (positionId.tickLower() != MIN_TICK || positionId.tickUpper() != MAX_TICK) revert FullRangeOnlyPool();
    } else {
        if (positionId.tickLower() >= positionId.tickUpper()) revert BoundsOrder();
        if (positionId.tickLower() < MIN_TICK || positionId.tickUpper() > MAX_TICK) revert MinMaxBounds();
        int32 spacing = int32(config.tickSpacing());
        if (positionId.tickLower() % spacing != 0 || positionId.tickUpper() % spacing != 0) revert BoundsTickSpacing();
    }
}
