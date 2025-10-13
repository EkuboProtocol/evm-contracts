// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Bitmap} from "../types/bitmap.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {StorageSlot} from "../types/storageSlot.sol";

// Addition of this offset does two things--it centers the 0 tick within a single bitmap regardless of tick spacing,
// and gives us a contiguous range of unsigned integers for all ticks
uint256 constant TICK_BITMAP_STORAGE_OFFSET = 89421695;

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
// Always rounds the tick down to the nearest multiple of tickSpacing
function tickToBitmapWordAndIndex(int32 tick, uint32 tickSpacing) pure returns (uint256 word, uint256 index) {
    assembly ("memory-safe") {
        let rawIndex := add(sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0)), TICK_BITMAP_STORAGE_OFFSET)
        word := shr(8, rawIndex)
        index := and(rawIndex, 0xff)
    }
}

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
/// @dev This function is only safe if tickSpacing is between 1 and MAX_TICK_SPACING, and word/index correspond to the results of tickToBitmapWordAndIndex for a tick between MIN_TICK and MAX_TICK
function bitmapWordAndIndexToTick(uint256 word, uint256 index, uint32 tickSpacing) pure returns (int32 tick) {
    assembly ("memory-safe") {
        let rawIndex := add(shl(8, word), index)
        tick := mul(sub(rawIndex, TICK_BITMAP_STORAGE_OFFSET), tickSpacing)
    }
}

function loadBitmap(StorageSlot slot, uint256 word) view returns (Bitmap bitmap) {
    bitmap = Bitmap.wrap(uint256(slot.add(word).load()));
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTick(StorageSlot slot, int32 tick, uint32 tickSpacing) {
    (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
    StorageSlot wordSlot = slot.add(word);
    wordSlot.store(wordSlot.load() ^ bytes32(1 << index));
}

function findNextInitializedTick(StorageSlot slot, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
    view
    returns (int32 nextTick, bool isInitialized)
{
    unchecked {
        nextTick = fromTick;

        while (true) {
            // convert the given tick to the bitmap position of the next nearest potential initialized tick
            (uint256 word, uint256 index) = tickToBitmapWordAndIndex(nextTick + int32(tickSpacing), tickSpacing);

            Bitmap bitmap = loadBitmap(slot, word);

            // find the index of the previous tick in that word
            uint256 nextIndex = bitmap.geSetBit(uint8(index));

            // if we found one, return it
            if (nextIndex != 256) {
                (nextTick, isInitialized) = (bitmapWordAndIndexToTick(word, nextIndex, tickSpacing), true);
                break;
            }

            // otherwise, return the tick of the most significant bit in the word
            nextTick = bitmapWordAndIndexToTick(word, 255, tickSpacing);

            if (nextTick >= MAX_TICK) {
                nextTick = MAX_TICK;
                break;
            }

            // if we are done searching, stop here
            if (skipAhead == 0) {
                break;
            }

            skipAhead--;
        }
    }
}

function findPrevInitializedTick(StorageSlot slot, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
    view
    returns (int32 prevTick, bool isInitialized)
{
    unchecked {
        prevTick = fromTick;

        while (true) {
            // convert the given tick to its bitmap position
            (uint256 word, uint256 index) = tickToBitmapWordAndIndex(prevTick, tickSpacing);

            Bitmap bitmap = loadBitmap(slot, word);

            // find the index of the previous tick in that word
            uint256 prevIndex = bitmap.leSetBit(uint8(index));

            if (prevIndex != 256) {
                (prevTick, isInitialized) = (bitmapWordAndIndexToTick(word, prevIndex, tickSpacing), true);
                break;
            }

            prevTick = bitmapWordAndIndexToTick(word, 0, tickSpacing);

            if (prevTick <= MIN_TICK) {
                prevTick = MIN_TICK;
                break;
            }

            if (skipAhead == 0) {
                break;
            }

            skipAhead--;
            prevTick--;
        }
    }
}
