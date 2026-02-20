// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice SignedExclusiveSwap per-pool state packed into a single word.
/// @dev Layout:
/// - bits [255..96]: controller (160 bits)
/// - bits [95..64]: last update time (uint32)
/// - bit  [63]: controller is EOA flag
type SignedExclusiveSwapPoolState is bytes32;

using {
    controller,
    lastUpdateTime,
    controllerIsEoa,
    withLastUpdateTime,
    withController
} for SignedExclusiveSwapPoolState global;

function controller(SignedExclusiveSwapPoolState state) pure returns (address result) {
    assembly ("memory-safe") {
        result := shr(96, state)
    }
}

function lastUpdateTime(SignedExclusiveSwapPoolState state) pure returns (uint32 result) {
    assembly ("memory-safe") {
        result := and(shr(64, state), 0xffffffff)
    }
}

function controllerIsEoa(SignedExclusiveSwapPoolState state) pure returns (bool result) {
    assembly ("memory-safe") {
        result := and(shr(63, state), 1)
    }
}

function createSignedExclusiveSwapPoolState(address _controller, uint32 _lastUpdateTime, bool _controllerIsEoa)
    pure
    returns (SignedExclusiveSwapPoolState state)
{
    assembly ("memory-safe") {
        state := or(or(shl(96, _controller), shl(64, _lastUpdateTime)), shl(63, iszero(iszero(_controllerIsEoa))))
    }
}

function withLastUpdateTime(SignedExclusiveSwapPoolState state, uint32 _lastUpdateTime)
    pure
    returns (SignedExclusiveSwapPoolState updated)
{
    assembly ("memory-safe") {
        updated := or(and(state, not(shl(64, 0xffffffff))), shl(64, _lastUpdateTime))
    }
}

function withController(SignedExclusiveSwapPoolState state, address _controller, bool _controllerIsEoa)
    pure
    returns (SignedExclusiveSwapPoolState updated)
{
    assembly ("memory-safe") {
        updated := or(
            and(state, 0x0000000000000000000000000000000000000000ffffffffffffffffffffffff),
            shl(96, _controller)
        )
        updated := or(and(updated, not(shl(63, 1))), shl(63, iszero(iszero(_controllerIsEoa))))
    }
}
