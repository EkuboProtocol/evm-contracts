// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

type Bitmap is uint256;

using {toggle, isSet, ltSetBit, geSetBit} for Bitmap global;

function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    result = Bitmap.wrap(Bitmap.unwrap(bitmap) ^ (1 << index));
}

function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(index, bitmap), 1)
    }
}

error LtSetBitZero();
// Returns the index of the bit that is set to true and less significant than index, or 0 if no such bit exists.

function ltSetBit(Bitmap bitmap, uint8 index) pure returns (uint8) {
    unchecked {
        if (index == 0) revert LtSetBitZero();

        // Mask out bits >= index.
        // e.g. if index = 10, we only keep bits [0..9].
        // (1 << index) - 1  sets those lower bits, then we & with the bitmap.
        uint256 bits = Bitmap.unwrap(bitmap);
        uint256 mask = (uint256(1) << index) - 1;
        uint256 masked = bits & mask;
        return uint8(FixedPointMathLib.log2(masked));
    }
}

// Returns the index of the bit that is set to true and more or equally significant to index, or 255 if no such bit exists.
function geSetBit(Bitmap bitmap, uint8 index) pure returns (uint8) {
    unchecked {
        uint256 bits = Bitmap.unwrap(bitmap);
        uint256 mask = ~((uint256(1) << index) - 1);
        uint256 masked = bits & mask;
        if (masked == 0) {
            // No bits set at or above index
            return 255;
        }
        // The lowest set bit in masked is found via (masked & -masked).
        // Then we use log2(...) to get the index.
        uint256 lowestSetBit = masked & (0 - masked); // or masked & (~masked + 1)
        return uint8(FixedPointMathLib.log2(lowestSetBit));
    }
}
