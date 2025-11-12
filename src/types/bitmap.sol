// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

/**
 * @title Bitmap (256-bit)
 * @notice Lightweight helpers for treating a `uint256` as a 256-bit bitmap.
 * @dev
 * - Bit indices are in the range [0, 255].
 * - All operations are O(1) and implemented with memory-safe assembly.
 * - For search helpers `leSetBit` and `geSetBit`, the return value is
 *   one-based: it returns `index + 1` of the matching set bit, or `0` if none.
 *   This convention avoids the need for sentinels outside the 0..255 range.
 */
type Bitmap is uint256;

using {toggle, isSet, leSetBit, geSetBit} for Bitmap global;

/**
 * @notice Toggle (flip) the bit at `index` in `bitmap`.
 * @param bitmap The current bitmap value.
 * @param index  Bit position to toggle, in [0, 255].
 * @return result A new bitmap with the bit at `index` flipped.
 */
function toggle(Bitmap bitmap, uint8 index) pure returns (Bitmap result) {
    assembly ("memory-safe") {
        result := xor(bitmap, shl(index, 1))
    }
}

/**
 * @notice Check whether the bit at `index` is set.
 * @param bitmap The bitmap to read.
 * @param index  Bit position to test, in [0, 255].
 * @return yes True if the bit is 1, false otherwise.
 */
function isSet(Bitmap bitmap, uint8 index) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(index, bitmap), 1)
    }
}

/**
 * @notice Find the most significant set bit at or below `index`.
 * @dev Returns one-based position: `pos = bitIndex + 1`, or `0` if none.
 *      Example: if bit 9 is set and `index >= 9`, returns `10`.
 *      For `index == 255`, the mask spans all bits (wraparound yields `2^256-1`).
 * @param bitmap The bitmap to search.
 * @param index  Upper bound (inclusive) for the search, in [0, 255].
 * @return v One-based position of MSB found (bitIndex + 1), or 0 if none.
 */
function leSetBit(Bitmap bitmap, uint8 index) pure returns (uint256 v) {
    unchecked {
        assembly ("memory-safe") {
            let masked := and(bitmap, sub(shl(add(index, 1), 1), 1))
            v := sub(256, clz(masked))
        }
    }
}

/**
 * @notice Find the least significant set bit at or above `index`.
 * @dev Returns one-based position: `pos = bitIndex + 1`, or `0` if none.
 *      Example: if bit 9 is set and `index <= 9`, returns `10`.
 * @param bitmap The bitmap to search.
 * @param index  Lower bound (inclusive) for the search, in [0, 255].
 * @return v One-based position of LSB found (bitIndex + 1), or 0 if none.
 */
function geSetBit(Bitmap bitmap, uint8 index) pure returns (uint256 v) {
    assembly ("memory-safe") {
        let masked := and(bitmap, not(sub(shl(index, 1), 1)))
        v := sub(256, clz(and(masked, sub(0, masked))))
    }
}
