// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

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

/// @notice Extracts the target order duration from buybacks state
/// @param state The buybacks state
/// @return duration The target order duration value, bounded by uint32
function targetOrderDuration(BuybacksState state) pure returns (uint256 duration) {
    assembly ("memory-safe") {
        duration := and(state, 0xFFFFFFFF)
    }
}

/// @notice Extracts the minimum order duration from buybacks state
/// @param state The buybacks state
/// @return duration The minimum order duration value, bounded by uint32
function minOrderDuration(BuybacksState state) pure returns (uint256 duration) {
    assembly ("memory-safe") {
        duration := and(shr(32, state), 0xFFFFFFFF)
    }
}

/// @notice Extracts the fee from buybacks state
/// @param state The buybacks state
/// @return f The fee value, bounded by uint64
function fee(BuybacksState state) pure returns (uint256 f) {
    assembly ("memory-safe") {
        f := and(shr(64, state), 0xFFFFFFFFFFFFFFFF)
    }
}

/// @notice Extracts the last end time from buybacks state
/// @param state The buybacks state
/// @return endTime The last end time value, bounded by uint32
function lastEndTime(BuybacksState state) pure returns (uint256 endTime) {
    assembly ("memory-safe") {
        endTime := and(shr(128, state), 0xFFFFFFFF)
    }
}

/// @notice Extracts the last order duration from buybacks state
/// @param state The buybacks state
/// @return duration The last order duration value, bounded by uint32
function lastOrderDuration(BuybacksState state) pure returns (uint256 duration) {
    assembly ("memory-safe") {
        duration := and(shr(160, state), 0xFFFFFFFF)
    }
}

/// @notice Extracts the last fee from buybacks state
/// @param state The buybacks state
/// @return f The last fee value, bounded by uint64
function lastFee(BuybacksState state) pure returns (uint256 f) {
    assembly ("memory-safe") {
        f := shr(192, state)
    }
}

function isConfigured(BuybacksState state) pure returns (bool) {
    return minOrderDuration(state) != 0;
}

/// @notice Parses all components from buybacks state
/// @param state The buybacks state
/// @return _targetOrderDuration The target order duration value, bounded by uint32
/// @return _minOrderDuration The minimum order duration value, bounded by uint32
/// @return _fee The fee value, bounded by uint64
/// @return _lastEndTime The last end time value, bounded by uint32
/// @return _lastOrderDuration The last order duration value, bounded by uint32
/// @return _lastFee The last fee value, bounded by uint64
function parse(BuybacksState state)
    pure
    returns (
        uint256 _targetOrderDuration,
        uint256 _minOrderDuration,
        uint256 _fee,
        uint256 _lastEndTime,
        uint256 _lastOrderDuration,
        uint256 _lastFee
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
        state :=
            or(
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
