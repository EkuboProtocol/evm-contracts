// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type LaunchInfo is bytes32;

using {endTime, creator, saleEndTick} for LaunchInfo global;

function endTime(LaunchInfo launchInfo) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := shr(192, launchInfo)
    }
}

function creator(LaunchInfo launchInfo) pure returns (address v) {
    assembly ("memory-safe") {
        v := shr(96, shl(64, launchInfo))
    }
}

function saleEndTick(LaunchInfo launchInfo) pure returns (address v) {
    assembly ("memory-safe") {
        v := signextend(3, launchInfo)
    }
}

function createLaunchInfo(uint64 _endTime, address _creator, int32 _saleEndTick) pure returns (LaunchInfo v) {
    assembly ("memory-safe") {
        v := or(or(shl(192, _endTime), shr(64, shl(96, _creator))), and(_saleEndTick, 0xffffffff))
    }
}
