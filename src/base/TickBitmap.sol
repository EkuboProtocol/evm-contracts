// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";
import {MIN_TICK, MAX_TICK} from "../math/ticks.sol";

function tickToBitmapWordAndIndex(int32 tick, uint32 tickSpacing) pure returns (uint256 word, uint8 index) {
    unchecked {
        uint256 rawIndex = uint256(int256((tick / int32(tickSpacing)) + 88723072));
        (word, index) = (rawIndex / 256, uint8(255 - (rawIndex % 256)));
    }
}

function bitmapWordAndIndexToTick(uint256 word, uint8 index, uint32 tickSpacing) pure returns (int32 tick) {
    unchecked {
        int256 rawIndex = int256(word * 256 + (255 - uint256(index)));
        tick = int32(rawIndex - 88723072) * int32(tickSpacing);
    }
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTick(mapping(uint256 word => Bitmap bitmap) storage map, int32 tick, uint32 tickSpacing) {
    (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
    map[word] = map[word].toggle(index);
}

function findNextInitializedTick(
    mapping(uint256 word => Bitmap bitmap) storage map,
    int32 fromTick,
    uint32 tickSpacing,
    uint256 skipAhead
) view returns (int32 nextTick, bool initialized) {
    unchecked {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick + 1, tickSpacing);
        while (true) {
            Bitmap bitmap = map[word];
            uint8 nextIndex = bitmap.leSetBit(uint8(index));
            nextTick = bitmapWordAndIndexToTick(word, uint8(nextIndex), tickSpacing);
            initialized = bitmap.isSet(nextIndex);
            if (initialized) {
                break;
            }
            if (nextTick >= MAX_TICK) {
                return (MAX_TICK, false);
            }
            if (skipAhead == 0) {
                return (nextTick, false);
            }

            skipAhead--;
            word++;
            index = 255;
        }
    }
}

function findPrevInitializedTick(
    mapping(uint256 word => Bitmap bitmap) storage map,
    int32 fromTick,
    uint32 tickSpacing,
    uint256 skipAhead
) view returns (int32 prevTick, bool initialized) {
    unchecked {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick, tickSpacing);
        while (true) {
            Bitmap bitmap = map[word];
            uint8 prevIndex = bitmap.geSetBit(uint8(index));
            prevTick = bitmapWordAndIndexToTick(word, uint8(prevIndex), tickSpacing);
            initialized = bitmap.isSet(prevIndex);
            if (initialized) {
                break;
            }
            if (prevTick <= MIN_TICK) {
                return (MIN_TICK, false);
            }
            if (skipAhead == 0) {
                return (prevTick, false);
            }

            skipAhead--;
            word--;
            index = 0;
        }
    }
}
