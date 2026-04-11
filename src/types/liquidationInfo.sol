// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type LiquidationInfo is bytes32;

using {startTime, duration, endTime, active, parse} for LiquidationInfo global;

function startTime(LiquidationInfo info) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(info, 0xFFFFFFFFFFFFFFFF)
    }
}

function duration(LiquidationInfo info) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(64, info), 0xFFFFFFFF)
    }
}

function endTime(LiquidationInfo info) pure returns (uint64) {
    return info.startTime() + uint64(info.duration());
}

function active(LiquidationInfo info) pure returns (bool) {
    return info.duration() != 0;
}

function parse(LiquidationInfo info) pure returns (uint64 _startTime, uint32 _duration) {
    _startTime = info.startTime();
    _duration = info.duration();
}

function createLiquidationInfo(uint64 _startTime, uint32 _duration) pure returns (LiquidationInfo info) {
    assembly ("memory-safe") {
        info := or(_startTime, shl(64, _duration))
    }
}
