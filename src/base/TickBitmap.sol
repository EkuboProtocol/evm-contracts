// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";

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

abstract contract TickBitmap {
    function flipTick(mapping(uint256 word => Bitmap bitmap) storage map, int32 tick, uint32 tickSpacing) internal {
        (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        map[word] = map[word].toggle(index);
    }

    // Returns the tick > fromTick that is initialized, or MAX_TICK if there is no such tick
    function findNextInitializedTick(
        mapping(uint256 word => Bitmap bitmap) storage map,
        int32 fromTick,
        uint256 skipAhead,
        uint32 tickSpacing
    ) internal view returns (int32 nextTick, bool initialized) {
        unchecked {
            (uint256 word, uint256 index) = tickToBitmapWordAndIndex(fromTick + 1, tickSpacing);
            while (true) {
                Bitmap bitmap = map[word];
                uint8 nextIndex = bitmap.leSetBit(uint8(index));
                if (bitmap.isSet(nextIndex)) {
                    return (bitmapWordAndIndexToTick(word, uint8(nextIndex), tickSpacing), true);
                }
                if (skipAhead == 0) {
                    return (bitmapWordAndIndexToTick(word, uint8(nextIndex), tickSpacing), false);
                }
                skipAhead--;
                word++;
                index = 255;
            }
        }
    }
}
