// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/// @notice Order configuration packed into a single bytes32
/// @dev Contains fee (8 bytes), isToken1 (1 byte), padding (7 bytes), start time (8 bytes), and end time (8 bytes)
type OrderConfig is bytes32;

using {fee, isToken1, startTime, endTime} for OrderConfig global;

/// @notice Extracts the fee from an order config
/// @param config The order config
/// @return r The fee value, bounded by uint64
function fee(OrderConfig config) pure returns (uint256 r) {
    assembly ("memory-safe") {
        r := shr(192, config)
    }
}

/// @notice Extracts isToken1 from an order config
/// @param config The order config
/// @return r Whether the order is selling token1
function isToken1(OrderConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        r := iszero(iszero(byte(8, config)))
    }
}

/// @notice Extracts the start time from an order config
/// @param config The order config
/// @return r The start time value, bounded by uint64
function startTime(OrderConfig config) pure returns (uint256 r) {
    assembly ("memory-safe") {
        r := and(shr(64, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the end time from an order config
/// @param config The order config
/// @return r The end time value, bounded by uint64
function endTime(OrderConfig config) pure returns (uint256 r) {
    assembly ("memory-safe") {
        r := and(config, 0xffffffffffffffff)
    }
}

/// @notice Creates an OrderConfig from individual components
/// @param _fee The fee of the TWAMM pool
/// @param _startTime The start time of the order
/// @param _endTime The end time of the order
/// @return c The packed configuration
function createOrderConfig(uint64 _fee, bool _isToken1, uint64 _startTime, uint64 _endTime)
    pure
    returns (OrderConfig c)
{
    assembly ("memory-safe") {
        // Mask inputs to ensure only relevant bits are used
        c :=
            add(
                add(shl(192, _fee), add(shl(184, iszero(iszero(_isToken1))), shl(64, and(_startTime, 0xffffffffffffffff)))),
                and(_endTime, 0xffffffffffffffff)
            )
    }
}
