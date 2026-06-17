// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type SingleTokenRewardsPoolState is bytes32;

using {lastAccumulated, realLastAccumulated, rewardRate, parse} for SingleTokenRewardsPoolState global;

function lastAccumulated(SingleTokenRewardsPoolState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

function realLastAccumulated(SingleTokenRewardsPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

function rewardRate(SingleTokenRewardsPoolState state) pure returns (uint224 rate) {
    assembly ("memory-safe") {
        rate := shr(32, state)
    }
}

function parse(SingleTokenRewardsPoolState state) pure returns (uint32 time, uint224 rate) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(32, state)
    }
}

function createSingleTokenRewardsPoolState(uint32 _lastAccumulated, uint224 _rewardRate)
    pure
    returns (SingleTokenRewardsPoolState s)
{
    assembly ("memory-safe") {
        // s = lastAccumulated | (rewardRate << 32)
        s := or(and(_lastAccumulated, 0xffffffff), shl(32, _rewardRate))
    }
}
