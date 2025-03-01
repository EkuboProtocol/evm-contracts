// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the time is initialized
// Always rounds the time down
function timeToBitmapWordAndIndex(uint32 time) pure returns (uint256 word, uint256 index) {
    assembly ("memory-safe") {
        let rawIndex := shr(4, time)
        word := div(rawIndex, 256)
        index := mod(rawIndex, 256)
    }
}

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
function bitmapWordAndIndexToTime(uint256 word, uint256 index) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := shl(4, add(mul(word, 256), index))
    }
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTime(mapping(uint256 word => Bitmap bitmap) storage map, uint32 time) {
    (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
    map[word] = map[word].toggle(uint8(index));
}

function findNextInitializedTime(mapping(uint256 word => Bitmap bitmap) storage map, uint32 fromTime)
    view
    returns (uint32 nextTime, bool isInitialized)
{
    unchecked {
        // convert the given time to the bitmap position of the next nearest potential initialized time
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime + 16);

        // find the index of the previous tick in that word
        uint256 nextIndex = map[word].geSetBit(uint8(index));

        // if we found one, return it
        if (nextIndex != 256) {
            (nextTime, isInitialized) = (bitmapWordAndIndexToTime(word, nextIndex), true);
        } else {
            // otherwise, return the time of the most significant bit in the word
            nextTime = bitmapWordAndIndexToTime(word, 255);
        }
    }
}
