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
    assembly ("memory-safe") {
        mstore(0, word)
        mstore(32, map.slot)
        let k := keccak256(0, 64)
        let v := sload(k)
        sstore(k, xor(v, shl(index, 1)))
    }
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

        return (bitmapWordAndIndexToTime(word, FixedPointMathLib.min(255, nextIndex)), nextIndex != 256);
    }
}

// Iteratively call findNextInitializedTime until we find an initialized time
function searchForNextInitializedTime(
    mapping(uint256 word => Bitmap bitmap) storage map,
    uint32 fromTime,
    uint32 untilTime
) view returns (uint32 nextTime, bool isInitialized) {
    unchecked {
        while (true) {
            (nextTime, isInitialized) = findNextInitializedTime(map, fromTime);
            // Check using modular arithmetic: if the found time is beyond untilTime, stop.
            if (nextTime - fromTime > untilTime - fromTime) {
                return (untilTime, false);
            }
            if (isInitialized) {
                return (nextTime, true);
            }
            fromTime = nextTime;
        }
    }
}
