// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Per-pool state of the MEVCapture v2.1 extension, packed into one storage word
/// @dev Layout (bits):
///   - [255..224]: lastUpdateTime (uint32), timestamp of the last anchor update
///   - [223..192]: lRefTime (uint32), when the gate reference last restarted
///   - [191..160]: lastPosTime (uint32), timestamp of the last position-update snapshot
///   - [159..152]: lRefBits (uint8), gate reference as a bit length of active liquidity
///   - [151..144]: snapBits (uint8), bit length of active liquidity before the first position update in lastPosTime
///   - [143..112]: lRefRaiseTime (uint32), when lRefBits was last increased
///   - [111..64]: reserved, always zero
///   - [63..0]: anchorX16 (int64), anchor tick as a Q48.16 number
type MEVCaptureV21PoolState is bytes32;

using {
    lastUpdateTime,
    lRefTime,
    lastPosTime,
    lRefBits,
    snapBits,
    lRefRaiseTime,
    anchorX16,
    withSnapshot
} for MEVCaptureV21PoolState global;

function lastUpdateTime(MEVCaptureV21PoolState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := shr(224, state)
    }
}

function lRefTime(MEVCaptureV21PoolState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(192, state), 0xffffffff)
    }
}

function lastPosTime(MEVCaptureV21PoolState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(160, state), 0xffffffff)
    }
}

function lRefBits(MEVCaptureV21PoolState state) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(shr(152, state), 0xff)
    }
}

function snapBits(MEVCaptureV21PoolState state) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(shr(144, state), 0xff)
    }
}

function lRefRaiseTime(MEVCaptureV21PoolState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(112, state), 0xffffffff)
    }
}

function anchorX16(MEVCaptureV21PoolState state) pure returns (int64 v) {
    assembly ("memory-safe") {
        v := signextend(7, state)
    }
}

/// @notice Returns the state with the position-update snapshot fields replaced
function withSnapshot(MEVCaptureV21PoolState state, uint32 _lastPosTime, uint8 _snapBits)
    pure
    returns (MEVCaptureV21PoolState s)
{
    assembly ("memory-safe") {
        s := or(
            and(state, not(or(shl(160, 0xffffffff), shl(144, 0xff)))),
            or(shl(160, and(_lastPosTime, 0xffffffff)), shl(144, and(_snapBits, 0xff)))
        )
    }
}

function createMEVCaptureV21PoolState(
    uint32 _lastUpdateTime,
    uint32 _lRefTime,
    uint32 _lastPosTime,
    uint8 _lRefBits,
    uint8 _snapBits,
    uint32 _lRefRaiseTime,
    int64 _anchorX16
) pure returns (MEVCaptureV21PoolState s) {
    assembly ("memory-safe") {
        s := or(
            or(
                or(shl(224, and(_lastUpdateTime, 0xffffffff)), shl(192, and(_lRefTime, 0xffffffff))),
                or(shl(160, and(_lastPosTime, 0xffffffff)), shl(152, and(_lRefBits, 0xff)))
            ),
            or(
                or(shl(144, and(_snapBits, 0xff)), shl(112, and(_lRefRaiseTime, 0xffffffff))),
                and(_anchorX16, 0xffffffffffffffff)
            )
        )
    }
}
