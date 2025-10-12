// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolConfig} from "./poolConfig.sol";

/// @notice Order configuration packed into a single bytes32
/// @dev Contains truncated pool config (12 bytes: fee + pool type), isToken1 (1 bit), padding, start time (8 bytes), and end time (8 bytes)
/// Layout:
///   - Bits 255-160 (96 bits): truncated pool config (fee 64 bits + pool type config 32 bits)
///   - Bit 159 (1 bit): isToken1
///   - Bits 158-128 (31 bits): padding
///   - Bits 127-64 (64 bits): start time
///   - Bits 63-0 (64 bits): end time
type OrderConfig is bytes32;

using {fee, poolTypeConfig, isToken1, startTime, endTime, toPoolConfig} for OrderConfig global;

/// @notice Extracts the fee from an order config
/// @param config The order config
/// @return r The fee
function fee(OrderConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(192, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the pool type config from an order config
/// @param config The order config
/// @return r The pool type config (32 bits)
function poolTypeConfig(OrderConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(shr(160, config), 0xffffffff)
    }
}

/// @notice Extracts isToken1 from an order config
/// @param config The order config
/// @return r Whether the order is selling token1
function isToken1(OrderConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        r := iszero(iszero(and(shr(159, config), 1)))
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

/// @notice Converts an OrderConfig to a PoolConfig by combining the truncated pool config with the extension address
/// @param config The order config
/// @param twamm The TWAMM extension address
/// @return poolConfig The full pool config
function toPoolConfig(OrderConfig config, address twamm) pure returns (PoolConfig poolConfig) {
    assembly ("memory-safe") {
        // Combine: extension (160 bits) | truncated pool config (96 bits: fee 64 bits + pool type 32 bits)
        // The truncated config is already in bits 255-160, so we just need to add the extension in bits 255-96
        poolConfig := add(shl(96, twamm), shr(160, config))
    }
}

/// @notice Creates an OrderConfig from individual components
/// @param _fee The fee of the TWAMM pool
/// @param _poolTypeConfig The pool type config (32 bits: discriminator + tick spacing or amplification + center)
/// @param _isToken1 Whether the order is selling token1
/// @param _startTime The start time of the order
/// @param _endTime The end time of the order
/// @return c The packed configuration
function createOrderConfig(uint64 _fee, uint32 _poolTypeConfig, bool _isToken1, uint64 _startTime, uint64 _endTime)
    pure
    returns (OrderConfig c)
{
    assembly ("memory-safe") {
        // Pack: truncated pool config (fee + pool type) | isToken1 | padding | start time | end time
        c :=
            add(
                add(
                    add(shl(192, and(_fee, 0xffffffffffffffff)), shl(160, and(_poolTypeConfig, 0xffffffff))),
                    shl(159, iszero(iszero(_isToken1)))
                ),
                add(shl(64, and(_startTime, 0xffffffffffffffff)), and(_endTime, 0xffffffffffffffff))
            )
    }
}
