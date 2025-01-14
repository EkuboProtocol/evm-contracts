// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

type Bitmap is uint256;

using {toggle, isSet, leSetBit, geSetBit} for Bitmap global;

function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    result = Bitmap.wrap(Bitmap.unwrap(bitmap) ^ (1 << index));
}

function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(index, bitmap), 1)
    }
}

// Returns the index of the bit that is set to true and less or equally significant than index, or 0 if no such bit exists.
function leSetBit(Bitmap bitmap, uint8 index) pure returns (uint8) {
    unchecked {
        uint256 bits = Bitmap.unwrap(bitmap);
        // generate a mask with all bits le index set to 1 without overflowing for index == 255
        uint256 mask = (index == 255) ? type(uint256).max : ((uint256(1) << (index + 1)) - 1);
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
            return type(uint8).max;
        }
        uint256 lowestSetBit = masked & (0 - masked); // or masked & (~masked + 1)
        return uint8(FixedPointMathLib.log2(lowestSetBit));
    }
}
