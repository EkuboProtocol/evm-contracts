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
/// @notice Thrown when the bounds of the position are outside the pool's min/max tick range
error MinMaxBounds();
/// @notice Thrown when the ticks of the bounds do not align with tick spacing for concentrated pools
error BoundsTickSpacing();

function validateBounds(PositionId positionId, PoolConfig config) pure {
    int32 _tickLower = positionId.tickLower();
    int32 _tickUpper = positionId.tickUpper();

    if (_tickLower >= _tickUpper) revert BoundsOrder();

    int32 _minTick = config.minTick();
    int32 _maxTick = config.maxTick();

    if (_tickLower < _minTick || _tickUpper > _maxTick) revert MinMaxBounds();

    // For concentrated liquidity pools, check tick spacing alignment
    if (config.isConcentrated()) {
        int32 spacing = int32(config.tickSpacing());
        if (_tickLower % spacing != 0 || _tickUpper % spacing != 0) revert BoundsTickSpacing();
    }
}
