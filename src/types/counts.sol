// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type Counts is bytes32;

using {index, count, capacity, lastTimestamp} for Counts global;

/// @notice Extracts the index from counts
/// @param counts The counts
/// @return i The index value, bounded by uint32
function index(Counts counts) pure returns (uint256 i) {
    assembly ("memory-safe") {
        i := and(counts, 0xFFFFFFFF)
    }
}

/// @notice Extracts the count from counts
/// @param counts The counts
/// @return c The count value, bounded by uint32
function count(Counts counts) pure returns (uint256 c) {
    assembly ("memory-safe") {
        c := shr(224, shl(192, counts))
    }
}

/// @notice Extracts the capacity from counts
/// @param counts The counts
/// @return c The capacity value, bounded by uint32
function capacity(Counts counts) pure returns (uint256 c) {
    assembly ("memory-safe") {
        c := shr(224, shl(160, counts))
    }
}

/// @notice Extracts the last timestamp from counts
/// @param counts The counts
/// @return t The last timestamp value, bounded by uint32
function lastTimestamp(Counts counts) pure returns (uint256 t) {
    assembly ("memory-safe") {
        t := shr(224, shl(128, counts))
    }
}

function createCounts(uint32 _index, uint32 _count, uint32 _capacity, uint32 _lastTimestamp) pure returns (Counts c) {
    assembly ("memory-safe") {
        // c = index | (count << 32) | (capacity << 64) | (lastTimestamp << 96)
        c :=
            or(
                or(or(and(_index, 0xFFFFFFFF), shl(32, and(_count, 0xFFFFFFFF))), shl(64, and(_capacity, 0xFFFFFFFF))),
                shl(96, and(_lastTimestamp, 0xFFFFFFFF))
            )
    }
}
