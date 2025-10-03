// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type TickInfo is bytes32;

using {liquidityDelta, positionCount, secondsOutside, parse} for TickInfo global;

function liquidityDelta(TickInfo info) pure returns (int128 delta) {
    assembly ("memory-safe") {
        delta := signextend(15, info)
    }
}

function positionCount(TickInfo info) pure returns (uint64 count) {
    assembly ("memory-safe") {
        count := and(shr(128, info), 0xFFFFFFFFFFFFFFFF)
    }
}

function secondsOutside(TickInfo info) pure returns (uint64 seconds_) {
    assembly ("memory-safe") {
        seconds_ := shr(192, info)
    }
}

function parse(TickInfo info) pure returns (int128 delta, uint64 count, uint64 seconds_) {
    assembly ("memory-safe") {
        delta := signextend(15, info)
        count := and(shr(128, info), 0xFFFFFFFFFFFFFFFF)
        seconds_ := shr(192, info)
    }
}

function createTickInfo(int128 _liquidityDelta, uint64 _positionCount, uint64 _secondsOutside)
    pure
    returns (TickInfo info)
{
    assembly ("memory-safe") {
        // info = (secondsOutside << 192) | (positionCount << 128) | liquidityDelta
        info := or(or(shl(192, _secondsOutside), shl(128, _positionCount)), shr(128, shl(128, _liquidityDelta)))
    }
}
