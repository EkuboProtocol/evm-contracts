// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

type Counts is bytes32;

using {index, count, capacity, lastTimestamp} for Counts global;

function index(Counts counts) pure returns (uint32 i) {
    assembly ("memory-safe") {
        i := and(counts, 0xFFFFFFFF)
    }
}

function count(Counts counts) pure returns (uint32 c) {
    assembly ("memory-safe") {
        c := shr(224, shl(192, counts))
    }
}

function capacity(Counts counts) pure returns (uint32 c) {
    assembly ("memory-safe") {
        c := shr(224, shl(160, counts))
    }
}

function lastTimestamp(Counts counts) pure returns (uint32 t) {
    assembly ("memory-safe") {
        t := shr(224, shl(128, counts))
    }
}

function createCounts(uint32 _index, uint32 _count, uint32 _capacity, uint32 _lastTimestamp) pure returns (Counts c) {
    assembly ("memory-safe") {
        // c = index | (count << 32) | (capacity << 64) | (lastTimestamp << 96)
        c := or(
            or(or(and(_index, 0xFFFFFFFF), shl(32, and(_count, 0xFFFFFFFF))), shl(64, and(_capacity, 0xFFFFFFFF))),
            shl(96, and(_lastTimestamp, 0xFFFFFFFF))
        )
    }
}
