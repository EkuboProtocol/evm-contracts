// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/// @notice Pool configuration packed into a single bytes32
/// @dev Contains extension address (20 bytes), fee (8 bytes), and tick spacing (4 bytes)
type PoolConfig is bytes32;

using {tickSpacing, fee, extension} for PoolConfig global;

/// @notice Extracts the tick spacing from a pool config
/// @param config The pool config
/// @return r The tick spacing
function tickSpacing(PoolConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(config, 0xffffffff)
    }
}

/// @notice Extracts the fee from a pool config
/// @param config The pool config
/// @return r The fee
function fee(PoolConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(32, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the extension address from a pool config
/// @param config The pool config
/// @return r The extension address
function extension(PoolConfig config) pure returns (address r) {
    assembly ("memory-safe") {
        r := shr(96, config)
    }
}

/// @notice Creates a PoolConfig from individual components
/// @param _fee The fee for the pool
/// @param _tickSpacing The tick spacing for the pool
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createPoolConfig(uint64 _fee, uint32 _tickSpacing, address _extension) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // Mask inputs to ensure only relevant bits are used
        c :=
            add(
                add(
                    shl(96, and(_extension, 0xffffffffffffffffffffffffffffffffffffffff)),
                    shl(32, and(_fee, 0xffffffffffffffff))
                ),
                and(_tickSpacing, 0xffffffff)
            )
    }
}
