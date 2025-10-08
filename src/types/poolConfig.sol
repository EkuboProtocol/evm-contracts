// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MAX_TICK, MAX_TICK_SPACING} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Pool configuration packed into a single bytes32
/// @dev Contains extension address (20 bytes), fee (8 bytes), and tick spacing (4 bytes)
type PoolConfig is bytes32;

using {
    tickSpacing,
    fee,
    extension,
    isFullRange,
    validate,
    mustLoadFees,
    maxLiquidityPerTickConcentratedLiquidity
} for PoolConfig global;

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

/// @notice Determines if this pool uses full-range-only tick spacing
/// @param config The pool config
/// @return r True if the pool uses full-range-only tick spacing
function isFullRange(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        r := iszero(and(config, 0xffffffff))
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
        c := or(or(shl(96, _extension), shl(32, and(_fee, 0xffffffffffffffff))), and(_tickSpacing, 0xffffffff))
    }
}

/// @notice Creates a PoolConfig for a pool that is full range
/// @param _fee The fee for the pool
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createFullRangePoolConfig(uint64 _fee, address _extension) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // Mask inputs to ensure only relevant bits are used
        c := or(shl(96, _extension), shl(32, and(_fee, 0xffffffffffffffff)))
    }
}

/// @notice Computes the maximum liquidity per tick for a given concentrated liquidity pool configuration.
/// For full-range-only pools (tickSpacing == 0), there are no individual ticks to limit
/// @dev Calculated as type(uint128).max / (1 + (MAX_TICK_MAGNITUDE / tickSpacing) * 2)
/// @param config The concentrated liquidity pool configuration
/// @return maxLiquidity The maximum liquidity allowed to reference each tick
function maxLiquidityPerTickConcentratedLiquidity(PoolConfig config) pure returns (uint128 maxLiquidity) {
    uint32 _tickSpacing = config.tickSpacing();

    // Calculate total number of usable ticks: 1 + (MAX_TICK_MAGNITUDE / tickSpacing) * 2
    // This represents all ticks from -MAX_TICK_MAGNITUDE to +MAX_TICK_MAGNITUDE, plus tick 0
    uint256 numTicks;
    assembly ("memory-safe") {
        // numTicks = 1 + (MAX_TICK_MAGNITUDE / tickSpacing) * 2
        numTicks := add(1, mul(div(MAX_TICK, _tickSpacing), 2))
    }

    unchecked {
        // maxLiquidity = type(uint128).max / numTicks
        maxLiquidity = uint128(FixedPointMathLib.rawDiv(type(uint128).max, numTicks));
    }
}

/// @notice Determines if fees must be loaded for swaps in this pool
/// @dev Returns true if either tick spacing or fee are nonzero
/// @param config The pool config
/// @return r True if fees must be loaded on swap
function mustLoadFees(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // only if either of tick spacing and fee are nonzero
        // if _both_ are zero, then we know we do not need to load fees for swaps
        r := iszero(iszero(and(config, 0xffffffffffffffffffffffff)))
    }
}

/// @notice Thrown when tick spacing exceeds the maximum allowed value
error InvalidTickSpacing();

/// @notice Validates that a pool key is properly formatted
/// @param config The config to validate
function validate(PoolConfig config) pure {
    if (config.tickSpacing() > MAX_TICK_SPACING) {
        revert InvalidTickSpacing();
    }
}
