// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type TWAMMRecoverableLiquidationState is bytes32;

using {activeOrderEndTime, active, parse} for TWAMMRecoverableLiquidationState global;

function activeOrderEndTime(TWAMMRecoverableLiquidationState state) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(state, 0xFFFFFFFFFFFFFFFF)
    }
}

function active(TWAMMRecoverableLiquidationState state) pure returns (bool v) {
    assembly ("memory-safe") {
        v := and(shr(64, state), 1)
    }
}

function parse(TWAMMRecoverableLiquidationState state) pure returns (uint64 _activeOrderEndTime, bool _active) {
    _activeOrderEndTime = state.activeOrderEndTime();
    _active = state.active();
}

function createTWAMMRecoverableLiquidationState(uint64 _activeOrderEndTime, bool _active)
    pure
    returns (TWAMMRecoverableLiquidationState state)
{
    assembly ("memory-safe") {
        state := or(and(_activeOrderEndTime, 0xFFFFFFFFFFFFFFFF), shl(64, _active))
    }
}
