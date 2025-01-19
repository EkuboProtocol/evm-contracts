// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";
import {MIN_TICK, MAX_TICK} from "../math/ticks.sol";

function floorDiv(int32 tick, uint32 tickSpacing) pure returns (int32 quotient) {
    assembly ("memory-safe") {
        quotient := sdiv(tick, tickSpacing)
        let remainder := smod(tick, tickSpacing)
        if slt(remainder, 0) { quotient := sub(quotient, 1) }
    }
}

// Aligns the tick to the nearest multiple of tickSpacing, rounded towards negative infinity
// e.g. floor(tick/tickSpacing) * tickSpacing
function alignTick(int32 tick, uint32 tickSpacing) pure returns (int32 r) {
    tick = floorDiv(tick, tickSpacing);
    assembly ("memory-safe") {
        r := mul(tick, tickSpacing)
    }
}

// Addition of this offset does two things--it centers the 0 tick within a single bitmap regardless of tick spacing,
// and gives us a contiguous range of unsigned integers for all ticks
int256 constant ABSOLUTE_MINIMUM_TICK_ARGUMENT_OFFSET = 89421695;

function tickToBitmapWordAndIndex(int32 tick, uint32 tickSpacing) pure returns (uint256 word, uint256 index) {
    unchecked {
        int256 spacingMultiple = floorDiv(tick, tickSpacing);

        uint256 rawIndex = uint256(spacingMultiple + ABSOLUTE_MINIMUM_TICK_ARGUMENT_OFFSET);
        (word, index) = (rawIndex / 256, rawIndex % 256);
    }
}

function bitmapWordAndIndexToTick(uint256 word, uint256 index, uint32 tickSpacing) pure returns (int32 tick) {
    unchecked {
        int256 rawIndex = int256(word * 256 + index);
        tick = int32(rawIndex - ABSOLUTE_MINIMUM_TICK_ARGUMENT_OFFSET) * int32(tickSpacing);
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
) view returns (int32, bool) {
    unchecked {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick + int32(tickSpacing), tickSpacing);
        Bitmap bitmap = map[word];
        uint256 nextIndex = bitmap.geSetBit(uint8(index));
        if (nextIndex != 256) {
            return (bitmapWordAndIndexToTick(word, nextIndex, tickSpacing), true);
        } else {
            int32 nextTick = bitmapWordAndIndexToTick(word, 255, tickSpacing);
            if (nextTick > MAX_TICK) {
                return (MAX_TICK, false);
            }
            if (skipAhead != 0) {
                return findNextInitializedTick(map, nextTick, tickSpacing, skipAhead - 1);
            }
            return (nextTick, false);
        }
    }
}

function findPrevInitializedTick(
    mapping(uint256 word => Bitmap bitmap) storage map,
    int32 fromTick,
    uint32 tickSpacing,
    uint256 skipAhead
) view returns (int32, bool) {
    unchecked {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick, tickSpacing);
        Bitmap bitmap = map[word];
        uint256 prevIndex = bitmap.leSetBit(uint8(index));

        if (prevIndex != 256) {
            return (bitmapWordAndIndexToTick(word, prevIndex, tickSpacing), true);
        } else {
            int32 prevTick = bitmapWordAndIndexToTick(word, 0, tickSpacing);
            if (prevTick < MIN_TICK) {
                return (bitmapWordAndIndexToTick(word, prevIndex, tickSpacing), false);
            }
            if (skipAhead != 0) {
                return findPrevInitializedTick(map, prevTick - 1, tickSpacing, skipAhead - 1);
            }
            return (prevTick, false);
        }
    }
}
