// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type MEVCapturePoolState is bytes32;

using {lastUpdateTime, tickLast, parse} for MEVCapturePoolState global;

function lastUpdateTime(MEVCapturePoolState state) pure returns (uint32 t) {
    assembly ("memory-safe") {
        t := shr(224, state)
    }
}

function tickLast(MEVCapturePoolState state) pure returns (int32 t) {
    assembly ("memory-safe") {
        t := signextend(31, shr(192, state))
    }
}

function parse(MEVCapturePoolState state) pure returns (uint32 lastUpdateTime_, int32 tickLast_) {
    assembly ("memory-safe") {
        lastUpdateTime_ := shr(224, state)
        tickLast_ := signextend(31, shr(192, state))
    }
}

function createMEVCapturePoolState(uint32 _lastUpdateTime, int32 _tickLast) pure returns (MEVCapturePoolState s) {
    assembly ("memory-safe") {
        // s = (lastUpdateTime << 224) | (tickLast << 192)
        s := or(shl(224, _lastUpdateTime), shr(32, shl(224, _tickLast)))
    }
}
