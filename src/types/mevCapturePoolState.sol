// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type MEVCapturePoolState is bytes32;

using {lastUpdateTime, tickLast} for MEVCapturePoolState global;

/// @notice Extracts the last update time from MEV capture pool state
/// @param state The MEV capture pool state
/// @return v The last update time value, bounded by uint32
function lastUpdateTime(MEVCapturePoolState state) pure returns (uint256 v) {
    assembly ("memory-safe") {
        v := shr(224, state)
    }
}

/// @notice Extracts the last tick from MEV capture pool state
/// @param state The MEV capture pool state
/// @return v The last tick value, bounded by int32
function tickLast(MEVCapturePoolState state) pure returns (int256 v) {
    assembly ("memory-safe") {
        v := signextend(3, state)
    }
}

function createMEVCapturePoolState(uint32 _lastUpdateTime, int32 _tickLast) pure returns (MEVCapturePoolState s) {
    assembly ("memory-safe") {
        // s = (lastUpdateTime << 224) | (tickLast << 192)
        s := or(shl(224, _lastUpdateTime), and(_tickLast, 0xffffffff))
    }
}
