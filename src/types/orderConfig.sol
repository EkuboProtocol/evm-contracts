// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/// @notice Order configuration packed into a single bytes32
/// @dev Contains fee (8 bytes), padding (8 bytes), start time (8 bytes), and end time (8 bytes)
type OrderConfig is bytes32;

using {fee, startTime, endTime} for OrderConfig global;

/// @notice Extracts the fee from an order config
/// @param config The order config
/// @return r The fee
function fee(OrderConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := shr(192, config)
    }
}

/// @notice Extracts the start time from an order config
/// @param config The order config
/// @return r The start time
function startTime(OrderConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(64, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the end time from an order config
/// @param config The order config
/// @return r The end time
function endTime(OrderConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(config, 0xffffffffffffffff)
    }
}

/// @notice Creates an OrderConfig from individual components
/// @param _fee The fee of the TWAMM pool
/// @param _startTime The start time of the order
/// @param _endTime The end time of the order
/// @return c The packed configuration
function createOrderConfig(uint64 _fee, uint64 _startTime, uint64 _endTime) pure returns (OrderConfig c) {
    assembly ("memory-safe") {
        // Mask inputs to ensure only relevant bits are used
        c := add(add(shl(192, _fee), shl(64, and(_startTime, 0xffffffffffffffff))), and(_endTime, 0xffffffffffffffff))
    }
}
