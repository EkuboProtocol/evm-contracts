// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";
import {MIN_TICK, MAX_TICK} from "../math/ticks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
// Addition of the offset does two things--it centers the 0 tick within a single bitmap regardless of tick spacing,
// and gives us a contiguous range of unsigned integers for all ticks
// Always rounds the tick down to the nearest multiple of tickSpacing
function tickToBitmapWordAndIndex(int32 tick, uint32 tickSpacing) pure returns (uint256 word, uint256 index) {
    assembly ("memory-safe") {
        let rawIndex := add(sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0)), 89421695)
        word := div(rawIndex, 256)
        index := mod(rawIndex, 256)
    }
}

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
function bitmapWordAndIndexToTick(uint256 word, uint256 index, uint32 tickSpacing) pure returns (int32 tick) {
    assembly ("memory-safe") {
        let rawIndex := add(mul(word, 256), index)
        tick := mul(sub(rawIndex, 89421695), tickSpacing)
    }
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTick(mapping(uint256 word => Bitmap bitmap) storage map, int32 tick, uint32 tickSpacing) {
    (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
    map[word] = map[word].toggle(uint8(index));
}

function findNextInitializedTick(
    mapping(uint256 word => Bitmap bitmap) storage map,
    int32 fromTick,
    uint32 tickSpacing,
    uint256 skipAhead
) view returns (int32 nextTick, bool isInitialized) {
    unchecked {
        nextTick = fromTick;
        while (nextTick < MAX_TICK) {
            // convert the given tick to the bitmap position of the next nearest potential initialized tick
            (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick + int32(tickSpacing), tickSpacing);

            // find the index of the previous tick in that word
            uint256 nextIndex = map[word].geSetBit(uint8(index));

            // if we found one, return it
            if (nextIndex != 256) {
                (nextTick, isInitialized) = (bitmapWordAndIndexToTick(word, nextIndex, tickSpacing), true);
                break;
            }

            // otherwise, return the tick of the most significant bit in the word
            nextTick = int32(FixedPointMathLib.min(MAX_TICK, bitmapWordAndIndexToTick(word, 255, tickSpacing)));

            // if we are done searching, stop here
            if (skipAhead == 0) {
                break;
            }
            skipAhead--;
        }
    }
}

function findPrevInitializedTick(
    mapping(uint256 word => Bitmap bitmap) storage map,
    int32 fromTick,
    uint32 tickSpacing,
    uint256 skipAhead
) view returns (int32 prevTick, bool isInitialized) {
    unchecked {
        prevTick = fromTick;
        while (prevTick > MIN_TICK) {
            // convert the given tick to its bitmap position
            (uint256 word, uint256 index) = tickToBitmapWordAndIndex(prevTick, tickSpacing);

            // find the index of the previous tick in that word
            uint256 prevIndex = map[word].leSetBit(uint8(index));

            if (prevIndex != 256) {
                (prevTick, isInitialized) = (bitmapWordAndIndexToTick(word, prevIndex, tickSpacing), true);
                break;
            }

            prevTick = int32(FixedPointMathLib.max(MIN_TICK, bitmapWordAndIndexToTick(word, 0, tickSpacing)));

            if (skipAhead == 0) {
                break;
            }
            skipAhead--;
        }
    }
}
