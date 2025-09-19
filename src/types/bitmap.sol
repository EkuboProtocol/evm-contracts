// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";

type Bitmap is uint256;

using {toggle, isSet, leSetBit, geSetBit} for Bitmap global;

function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    assembly ("memory-safe") {
        result := xor(bitmap, shl(index, 1))
    }
}

function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(index, bitmap), 1)
    }
}

// Returns the index of the most significant bit that is set _and_ less or equally significant to index, or 256 if no such bit exists.
function leSetBit(Bitmap bitmap, uint8 index) pure returns (uint256) {
    unchecked {
        uint256 masked;
        assembly ("memory-safe") {
            masked := and(bitmap, sub(shl(add(index, 1), 1), 1))
        }
        return LibBit.fls(masked);
    }
}

// Returns the index of the least significant bit that is set _and_ more or equally significant to index, or 256 if no such bit exists.
function geSetBit(Bitmap bitmap, uint8 index) pure returns (uint256) {
    unchecked {
        uint256 masked;
        assembly ("memory-safe") {
            masked := and(bitmap, not(sub(shl(index, 1), 1)))
        }
        return LibBit.ffs(masked);
    }
}
