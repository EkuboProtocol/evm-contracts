// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

type Counts is bytes32;

using {index, count, capacity, lastTimestamp} for Counts global;

function index(Counts counts) pure returns (uint32 i) {
    assembly ("memory-safe") {
        i := and(counts, 0xFFFFFFFF)
    }
}

function count(Counts counts) pure returns (uint32 c) {
    assembly ("memory-safe") {
        c := and(shr(32, counts), 0xFFFFFFFF)
    }
}

function capacity(Counts counts) pure returns (uint32 c) {
    assembly ("memory-safe") {
        c := and(shr(64, counts), 0xFFFFFFFF)
    }
}

function lastTimestamp(Counts counts) pure returns (uint32 t) {
    assembly ("memory-safe") {
        t := and(shr(96, counts), 0xFFFFFFFF)
    }
}

function createCounts(uint32 _index, uint32 _count, uint32 _capacity, uint32 _lastTimestamp) pure returns (Counts c) {
    assembly ("memory-safe") {
        // c = index | (count << 32) | (capacity << 64) | (lastTimestamp << 96)
        c := or(or(or(_index, shl(32, _count)), shl(64, _capacity)), shl(96, _lastTimestamp))
    }
}
