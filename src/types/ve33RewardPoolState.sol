// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed LP reward state for a pool.
/// @dev Low 32 bits store `lastAccumulated`; high 224 bits store the Q32 reward rate.
type Ve33RewardPoolState is bytes32;

using {lastAccumulated, realLastAccumulated, rewardRate, parseRewardPoolState} for Ve33RewardPoolState global;

/// @notice Returns the truncated timestamp when the pool reward state last accumulated.
function lastAccumulated(Ve33RewardPoolState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

/// @notice Returns the full timestamp corresponding to the packed 32-bit last-accumulated time.
/// @dev Reconstructs the timestamp closest to `block.timestamp` to tolerate 32-bit wraparound.
function realLastAccumulated(Ve33RewardPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

/// @notice Returns the current Q32 reward rate in reward tokens per second.
function rewardRate(Ve33RewardPoolState state) pure returns (uint224 rate) {
    assembly ("memory-safe") {
        rate := shr(32, state)
    }
}

/// @notice Parses the packed pool reward state.
/// @return time Truncated last-accumulated timestamp.
/// @return rate Current Q32 reward rate in reward tokens per second.
function parseRewardPoolState(Ve33RewardPoolState state) pure returns (uint32 time, uint224 rate) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(32, state)
    }
}

/// @notice Packs a reward pool state value.
/// @param _lastAccumulated Truncated last-accumulated timestamp.
/// @param _rewardRate Current Q32 reward rate in reward tokens per second.
function createVe33RewardPoolState(uint32 _lastAccumulated, uint224 _rewardRate) pure returns (Ve33RewardPoolState s) {
    assembly ("memory-safe") {
        s := or(and(_lastAccumulated, 0xffffffff), shl(32, _rewardRate))
    }
}
