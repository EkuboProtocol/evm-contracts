// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Returns whether `value` is an exact power of four.
function isPowerOfFour(uint256 value) pure returns (bool result) {
    assembly ("memory-safe") {
        result := and(
            iszero(and(value, sub(value, 1))),
            iszero(iszero(and(value, 0x5555555555555555555555555555555555555555555555555555555555555555)))
        )
    }
}
