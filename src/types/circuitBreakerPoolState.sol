// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type CircuitBreakerPoolState is bytes32;

using {lastSwapTimestamp, blockStartTick} for CircuitBreakerPoolState global;

function lastSwapTimestamp(CircuitBreakerPoolState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := shr(32, and(state, 0xffffffffffffffff00000000))
    }
}

function blockStartTick(CircuitBreakerPoolState state) pure returns (int32 v) {
    assembly ("memory-safe") {
        v := signextend(3, state)
    }
}

function createCircuitBreakerPoolState(uint32 _lastSwapTimestamp, int32 _blockStartTick)
    pure
    returns (CircuitBreakerPoolState s)
{
    assembly ("memory-safe") {
        s := or(shl(32, and(_lastSwapTimestamp, 0xffffffff)), and(_blockStartTick, 0xffffffff))
    }
}
