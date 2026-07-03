// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Canonical stake identifier storing `bytes24 salt || uint64 endTime`.
type StakeId is bytes32;

using {salt, endTime} for StakeId global;

/// @notice Returns the caller-selected stake salt.
function salt(StakeId stakeId) pure returns (bytes24 v) {
    assembly ("memory-safe") {
        v := shl(64, shr(64, stakeId))
    }
}

/// @notice Returns the timestamp when the stake may be unstaked.
function endTime(StakeId stakeId) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := stakeId
    }
}

/// @notice Creates a packed stake id from salt and end time.
function createStakeId(bytes24 _salt, uint64 _endTime) pure returns (StakeId v) {
    assembly ("memory-safe") {
        v := or(shl(64, shr(64, _salt)), and(_endTime, 0xffffffffffffffff))
    }
}
