// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

type BuybacksState is bytes32;

using {
    targetOrderDuration,
    minOrderDuration,
    fee,
    lastEndTime,
    lastOrderDuration,
    lastFee,
    isConfigured,
    parse
} for BuybacksState global;

function targetOrderDuration(BuybacksState state) pure returns (uint32 duration) {
    assembly ("memory-safe") {
        duration := and(state, 0xFFFFFFFF)
    }
}

function minOrderDuration(BuybacksState state) pure returns (uint32 duration) {
    assembly ("memory-safe") {
        duration := and(shr(32, state), 0xFFFFFFFF)
    }
}

function fee(BuybacksState state) pure returns (uint64 f) {
    assembly ("memory-safe") {
        f := and(shr(64, state), 0xFFFFFFFFFFFFFFFF)
    }
}

function lastEndTime(BuybacksState state) pure returns (uint32 endTime) {
    assembly ("memory-safe") {
        endTime := and(shr(128, state), 0xFFFFFFFF)
    }
}

function lastOrderDuration(BuybacksState state) pure returns (uint32 duration) {
    assembly ("memory-safe") {
        duration := and(shr(160, state), 0xFFFFFFFF)
    }
}

function lastFee(BuybacksState state) pure returns (uint64 f) {
    assembly ("memory-safe") {
        f := shr(192, state)
    }
}

function isConfigured(BuybacksState state) pure returns (bool) {
    return minOrderDuration(state) != 0;
}

function parse(BuybacksState state)
    pure
    returns (
        uint32 _targetOrderDuration,
        uint32 _minOrderDuration,
        uint64 _fee,
        uint32 _lastEndTime,
        uint32 _lastOrderDuration,
        uint64 _lastFee
    )
{
    assembly ("memory-safe") {
        _targetOrderDuration := and(state, 0xFFFFFFFF)
        _minOrderDuration := and(shr(32, state), 0xFFFFFFFF)
        _fee := and(shr(64, state), 0xFFFFFFFFFFFFFFFF)
        _lastEndTime := and(shr(128, state), 0xFFFFFFFF)
        _lastOrderDuration := and(shr(160, state), 0xFFFFFFFF)
        _lastFee := shr(192, state)
    }
}

function createBuybacksState(
    uint32 _targetOrderDuration,
    uint32 _minOrderDuration,
    uint64 _fee,
    uint32 _lastEndTime,
    uint32 _lastOrderDuration,
    uint64 _lastFee
) pure returns (BuybacksState state) {
    assembly ("memory-safe") {
        state := or(
            or(
                or(and(_targetOrderDuration, 0xFFFFFFFF), shl(32, and(_minOrderDuration, 0xFFFFFFFF))),
                shl(64, and(_fee, 0xFFFFFFFFFFFFFFFF))
            ),
            or(
                or(shl(128, and(_lastEndTime, 0xFFFFFFFF)), shl(160, and(_lastOrderDuration, 0xFFFFFFFF))),
                shl(192, _lastFee)
            )
        )
    }
}
