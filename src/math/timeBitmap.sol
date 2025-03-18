// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "../math/bitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {nextValidTime} from "../math/time.sol";

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the time is initialized
// Always rounds the time down
function timeToBitmapWordAndIndex(uint256 time) pure returns (uint256 word, uint256 index) {
    assembly ("memory-safe") {
        let rawIndex := shr(4, time)
        word := div(rawIndex, 256)
        index := mod(rawIndex, 256)
    }
}

// Returns the index of the word and the index _in_ that word which contains the bit representing whether the tick is initialized
function bitmapWordAndIndexToTime(uint256 word, uint256 index) pure returns (uint256 time) {
    assembly ("memory-safe") {
        time := shl(4, add(mul(word, 256), index))
    }
}

// Flips the tick in the bitmap from true to false or vice versa
function flipTime(mapping(uint256 word => Bitmap bitmap) storage map, uint256 time) {
    (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
    assembly ("memory-safe") {
        mstore(0, word)
        mstore(32, map.slot)
        let k := keccak256(0, 64)
        let v := sload(k)
        sstore(k, xor(v, shl(index, 1)))
    }
}

/// @dev Finds the smallest time that is equal to or greater than the given `fromTime`, initialized and stored in the next bitmap
///      If no initialized time is found, returns the greatest time in the bitmap
function findNextInitializedTime(mapping(uint256 word => Bitmap bitmap) storage map, uint256 fromTime)
    view
    returns (uint256 nextTime, bool isInitialized)
{
    unchecked {
        // convert the given time to the bitmap position of the next nearest potential initialized time
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);

        // find the index of the previous tick in that word
        uint256 nextIndex = map[word].geSetBit(uint8(index));

        return (bitmapWordAndIndexToTime(word, FixedPointMathLib.min(255, nextIndex)), nextIndex != 256);
    }
}

/// @dev Returns the smallest time that is greater than fromTime, less than or equal to untilTime and whether it is initialized
/// @param lastVirtualOrderExecutionTime Used to determine the next possible valid time to search
/// @param fromTime The time after which to start the search
/// @param untilTime The time where to end the search, i.e. this function will return at most the value passed to `untilTime`
function searchForNextInitializedTime(
    mapping(uint256 word => Bitmap bitmap) storage map,
    uint256 lastVirtualOrderExecutionTime,
    uint256 fromTime,
    uint256 untilTime
) view returns (uint256 nextTime, bool isInitialized) {
    unchecked {
        nextTime = fromTime;
        while (!isInitialized && nextTime != untilTime) {
            (nextTime, isInitialized) =
                findNextInitializedTime(map, nextValidTime(lastVirtualOrderExecutionTime, nextTime));
            if (nextTime - fromTime > untilTime - fromTime) {
                nextTime = untilTime;
                isInitialized = false;
            }
        }
    }
}
