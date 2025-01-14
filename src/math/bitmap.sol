// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

type Bitmap is uint256;

using {toggle, isSet} for Bitmap global;

function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    result = Bitmap.wrap(Bitmap.unwrap(bitmap) ^ (1 << index));
}

function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(index, bitmap), 1)
    }
}

// Returns the index of the bit that is set to true and less significant than fromIndex, or (0, false) if no such bit exists
function nextSetBit(Bitmap bitmap, uint8 fromIndex) pure returns (uint8 index, bool initialized) {
    // use bit masks and operations to find the next set bit optimally
}

// Returns the index of the bit that is set to true and more or equally significant to fromIndex, or (255, false) if no such bit exists
function prevSetBit(Bitmap bitmap, uint8 fromIndex) pure returns (uint8 index, bool initialized) {}
