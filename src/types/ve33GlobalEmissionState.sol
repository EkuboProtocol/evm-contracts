// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type Ve33GlobalEmissionState is bytes32;

using {emissionRate, lastAccrued, realEmissionTimeAtOrBeforeNow, parse} for Ve33GlobalEmissionState global;

/// @notice Returns the current global Q32 emission rate.
function emissionRate(Ve33GlobalEmissionState state) pure returns (uint160 rate) {
    assembly ("memory-safe") {
        rate := shr(96, shl(96, state))
    }
}

/// @notice Returns the last timestamp when global emissions were accrued.
function lastAccrued(Ve33GlobalEmissionState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(shr(160, state), 0xffffffff)
    }
}

/// @notice Returns the latest full timestamp at or before now matching the packed last-accrued timestamp.
/// @dev Mirrors TWAMM's packed-time recovery for `lastVirtualOrderExecutionTime`.
function realEmissionTimeAtOrBeforeNow(Ve33GlobalEmissionState state) view returns (uint256 realTime) {
    uint32 time = state.lastAccrued();
    unchecked {
        realTime = block.timestamp - (uint32(block.timestamp) - time);
    }
}

/// @notice Returns all fields in the packed global emission state.
function parse(Ve33GlobalEmissionState state) pure returns (uint160 rate, uint32 time) {
    assembly ("memory-safe") {
        rate := shr(96, shl(96, state))
        time := and(shr(160, state), 0xffffffff)
    }
}

/// @notice Creates a packed Ve33 global emission state.
function createVe33GlobalEmissionState(uint160 rate, uint32 lastAccruedTime)
    pure
    returns (Ve33GlobalEmissionState state)
{
    assembly ("memory-safe") {
        state := or(shr(96, shl(96, rate)), shl(160, and(lastAccruedTime, 0xffffffff)))
    }
}
