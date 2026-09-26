// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Promised rate and activation second of the most recently displaced same-start
/// pending bid, packed into a single word: the rate occupies the high 96 bits and the
/// activation second the low 48 bits. The zero value means no floor.
type PendingFloor is bytes32;

using {floorRate, floorStart} for PendingFloor global;

/// @notice Extracts the promised rate from a pending floor.
function floorRate(PendingFloor floor) pure returns (uint96 v) {
    assembly ("memory-safe") {
        v := shr(160, floor)
    }
}

/// @notice Extracts the activation second the floor applies to from a pending floor.
function floorStart(PendingFloor floor) pure returns (uint48 v) {
    assembly ("memory-safe") {
        v := and(floor, 0xffffffffffff)
    }
}

/// @notice Creates a pending floor from a promised rate and activation second.
function createPendingFloor(uint96 _rate, uint48 _start) pure returns (PendingFloor v) {
    assembly ("memory-safe") {
        v := or(shl(160, and(_rate, 0xffffffffffffffffffffffff)), and(_start, 0xffffffffffff))
    }
}
