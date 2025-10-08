// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, MAX_TICK_MAGNITUDE} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Pool configuration packed into a single bytes32
/// @dev Contains extension address (20 bytes), fee (8 bytes), and pool type config (4 bytes)
/// Pool type config (32 bits):
///   - Bit 31: discriminator (1 = concentrated, 0 = stableswap)
///   - For concentrated (bit 31 = 1): bits 30-0 are tick spacing
///   - For stableswap (bit 31 = 0): bits 30-24 are amplification factor, bits 23-0 are center tick
type PoolConfig is bytes32;

using {
    tickSpacing,
    fee,
    extension,
    isConcentrated,
    isStableswap,
    isFullRange,
    amplificationFactor,
    centerTick,
    minTick,
    maxTick,
    validate,
    maxLiquidityPerTickConcentratedLiquidity
} for PoolConfig global;

/// @notice Checks if this is a concentrated liquidity pool
/// @param config The pool config
/// @return r True if the pool is concentrated liquidity
function isConcentrated(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // Check if bit 31 is set
        r := shr(31, and(config, 0xffffffff))
    }
}

/// @notice Checks if this is a stableswap pool
/// @param config The pool config
/// @return r True if the pool is stableswap
function isStableswap(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // Check if bit 31 is not set
        r := iszero(shr(31, and(config, 0xffffffff)))
    }
}

/// @notice Extracts the tick spacing from a concentrated liquidity pool config
/// @dev Only valid for concentrated liquidity pools (isConcentrated() == true)
/// @param config The pool config
/// @return r The tick spacing
function tickSpacing(PoolConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        // Extract lower 31 bits (bits 30-0)
        r := and(config, 0x7fffffff)
    }
}

/// @notice Extracts the amplification factor from a stableswap pool config
/// @dev Only valid for stableswap pools (isStableswap() == true)
/// @param config The pool config
/// @return r The amplification factor (0-127)
function amplificationFactor(PoolConfig config) pure returns (uint8 r) {
    assembly ("memory-safe") {
        // Extract bits 30-24
        r := and(shr(24, config), 0x7f)
    }
}

/// @notice Extracts the center tick from a stableswap pool config
/// @dev Only valid for stableswap pools (isStableswap() == true)
/// @dev The 24-bit center tick is scaled by 16 to get the actual tick
/// @param config The pool config
/// @return r The center tick
function centerTick(PoolConfig config) pure returns (int32 r) {
    assembly ("memory-safe") {
        // Extract bits 23-0 and sign extend to 32 bits (24-bit signed integer)
        let centerTick24 := signextend(2, and(config, 0xffffff))
        // Multiply by 16 to scale to actual tick value
        r := mul(centerTick24, 16)
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

/// @notice Determines if this pool is full range (stableswap with amplification=0 and center=0)
/// @param config The pool config
/// @return r True if the pool is full range
function isFullRange(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // Full range when all 32 bits are 0 (discriminator=0, amplification=0, center=0)
        r := iszero(and(config, 0xffffffff))
    }
}

/// @notice Computes the minimum tick for this pool
/// @param config The pool config
/// @return r The minimum tick
function minTick(PoolConfig config) pure returns (int32 r) {
    if (config.isConcentrated()) {
        // Concentrated pools use the full tick range
        r = MIN_TICK;
    } else {
        // Stableswap pools: center - (MAX_TICK_MAGNITUDE >> amplification)
        // Clamped to MIN_TICK to ensure valid tick range
        int32 center = config.centerTick();
        uint32 range = MAX_TICK_MAGNITUDE >> config.amplificationFactor();
        int256 result;
        assembly ("memory-safe") {
            result := sub(center, range)
        }
        r = int32(FixedPointMathLib.max(MIN_TICK, result));
    }
}

/// @notice Computes the maximum tick for this pool
/// @param config The pool config
/// @return r The maximum tick
function maxTick(PoolConfig config) pure returns (int32 r) {
    if (config.isConcentrated()) {
        // Concentrated pools use the full tick range
        r = MAX_TICK;
    } else {
        // Stableswap pools: center + (MAX_TICK_MAGNITUDE >> amplification)
        // Clamped to MAX_TICK to ensure valid tick range
        int32 center = config.centerTick();
        uint32 range = MAX_TICK_MAGNITUDE >> config.amplificationFactor();
        int256 result;
        assembly ("memory-safe") {
            result := add(center, range)
        }
        r = int32(FixedPointMathLib.min(MAX_TICK, result));
    }
}

/// @notice Creates a PoolConfig for a concentrated liquidity pool
/// @param _fee The fee for the pool
/// @param _tickSpacing The tick spacing for the pool
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createPoolConfig(uint64 _fee, uint32 _tickSpacing, address _extension) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // Set bit 31 to 1 for concentrated liquidity, then OR with tick spacing (bits 30-0)
        let typeConfig := or(0x80000000, and(_tickSpacing, 0x7fffffff))
        c := or(or(shl(96, _extension), shl(32, and(_fee, 0xffffffffffffffff))), typeConfig)
    }
}

/// @notice Creates a PoolConfig for a stableswap pool
/// @param _fee The fee for the pool
/// @param _amplificationFactor The amplification factor (0-127)
/// @param _centerTick The center tick (will be divided by 16 and stored as 24-bit value)
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createStableswapPoolConfig(uint64 _fee, uint8 _amplificationFactor, int32 _centerTick, address _extension)
    pure
    returns (PoolConfig c)
{
    assembly ("memory-safe") {
        // Divide center tick by 16 to get 24-bit representation
        let centerTick24 := sdiv(_centerTick, 16)
        // Pack: bit 31 = 0 (stableswap), bits 30-24 = amplification, bits 23-0 = center tick
        let typeConfig := or(shl(24, and(_amplificationFactor, 0x7f)), and(centerTick24, 0xffffff))
        c := or(or(shl(96, _extension), shl(32, and(_fee, 0xffffffffffffffff))), typeConfig)
    }
}

/// @notice Creates a PoolConfig for a full range pool (stableswap with amplification=0, center=0)
/// @param _fee The fee for the pool
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createFullRangePoolConfig(uint64 _fee, address _extension) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // All 32 bits of type config are 0 (discriminator=0, amplification=0, center=0)
        c := or(shl(96, _extension), shl(32, and(_fee, 0xffffffffffffffff)))
    }
}

/// @notice Computes the maximum liquidity per tick for a given concentrated liquidity pool configuration.
/// @dev Only valid for concentrated liquidity pools. Stableswap pools don't use ticks.
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

/// @notice Thrown when tick spacing exceeds the maximum allowed value
error InvalidTickSpacing();

/// @notice Thrown when amplification factor exceeds the maximum allowed value
error InvalidAmplificationFactor();

/// @notice Validates that a pool config is properly formatted
/// @param config The config to validate
function validate(PoolConfig config) pure {
    if (config.isConcentrated()) {
        if (config.tickSpacing() > MAX_TICK_SPACING) {
            revert InvalidTickSpacing();
        }
    } else {
        // Stableswap pool: validate amplification factor <= 26
        if (config.amplificationFactor() > 26) {
            revert InvalidAmplificationFactor();
        }
    }
}
