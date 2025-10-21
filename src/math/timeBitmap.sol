// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Bitmap} from "../types/bitmap.sol";
import {nextValidTime} from "../math/time.sol";
import {StorageSlot} from "../types/storageSlot.sol";

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the time is initialized
// Always rounds the time down
function timeToBitmapWordAndIndex(uint256 time) pure returns (uint256 word, uint256 index) {
    assembly ("memory-safe") {
        word := shr(12, time)
        index := and(shr(4, time), 0xff)
    }
}

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
/// @dev Assumes word is less than 2**252 and index is less than 2**8
function bitmapWordAndIndexToTime(uint256 word, uint256 index) pure returns (uint256 time) {
    assembly ("memory-safe") {
        time := add(shl(12, word), shl(4, index))
    }
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTime(StorageSlot slot, uint256 time) {
    (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
    StorageSlot wordSlot = slot.add(word);
    wordSlot.store(wordSlot.load() ^ bytes32(uint256(1) << (255 - index)));
}

/// @dev Finds the smallest time that is equal to or greater than the given `fromTime`, initialized and stored in the next bitmap
///      If no initialized time is found, returns the greatest time in the bitmap
function findNextInitializedTime(StorageSlot slot, uint256 fromTime)
    view
    returns (uint256 nextTime, bool isInitialized)
{
    unchecked {
        // convert the given time to the bitmap position of the next nearest potential initialized time
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);

        // find the index of the next time in that word
        Bitmap bitmap = Bitmap.wrap(uint256(slot.add(word).load()));
        // Convert from old (LSB=0) to new (MSB=0) index space
        // Finding min oldIndex >= index requires max newIndex <= (255-index)
        uint256 nextIndex = bitmap.leSetBit(uint8(255 - index));

        // Convert back from new to old index space and handle sentinel
        if (nextIndex != 256) {
            nextIndex = 255 - nextIndex;
            isInitialized = true;
        } else {
            nextIndex = 255;
            isInitialized = false;
        }

        nextTime = bitmapWordAndIndexToTime(word, nextIndex);
    }
}

/// @dev Returns the smallest time that is greater than fromTime, less than or equal to untilTime and whether it is initialized
/// @param lastVirtualOrderExecutionTime Used to determine the next possible valid time to search
/// @param fromTime The time after which to start the search
/// @param untilTime The time where to end the search, i.e. this function will return at most the value passed to `untilTime`
function searchForNextInitializedTime(
    StorageSlot slot,
    uint256 lastVirtualOrderExecutionTime,
    uint256 fromTime,
    uint256 untilTime
) view returns (uint256 nextTime, bool isInitialized) {
    unchecked {
        nextTime = fromTime;
        while (!isInitialized && nextTime != untilTime) {
            uint256 nextValid = nextValidTime(lastVirtualOrderExecutionTime, nextTime);
            // if there is no valid time after the given nextTime, just return untilTime
            if (nextValid == 0) {
                nextTime = untilTime;
                isInitialized = false;
                break;
            }
            (nextTime, isInitialized) = findNextInitializedTime(slot, nextValid);
            if (nextTime > untilTime) {
                nextTime = untilTime;
                isInitialized = false;
            }
        }
    }
}
