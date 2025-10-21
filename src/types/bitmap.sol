// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

// Bitmap type where index 0 = MSB (bit 255), index 255 = LSB (bit 0)
// This ordering allows efficient use of the clz (count leading zeros) opcode
type Bitmap is uint256;

using {toggle, isSet, leSetBit, geSetBit} for Bitmap global;

function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    assembly ("memory-safe") {
        result := xor(bitmap, shl(sub(255, index), 1))
    }
}

function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(sub(255, index), bitmap), 1)
    }
}

// Returns the index of the most significant bit that is set _and_ less or equally significant to index, or 256 if no such bit exists.
function leSetBit(Bitmap bitmap, uint8 index) pure returns (uint256 v) {
    assembly ("memory-safe") {
        let masked := and(bitmap, not(sub(shl(sub(255, index), 1), 1)))
        v := clz(masked)
    }
}

// Returns the index of the least significant bit that is set _and_ more or equally significant to index, or 256 if no such bit exists.
function geSetBit(Bitmap bitmap, uint8 index) pure returns (uint256 v) {
    assembly ("memory-safe") {
        let masked := and(bitmap, sub(shl(sub(256, index), 1), 1))
        v := clz(masked)
    }
}
