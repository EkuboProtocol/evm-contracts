// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, MAX_TICK_SPACING_EXP} from "../math/constants.sol";

/// @notice Pool configuration packed into a single bytes32
/// @dev Layout (bits):
///   - [255..96]: extension address (160 bits)
///   - [95..80]: fee (16 bits, 0.16 fixed point, i.e. `fee / 2**16` of the input)
///   - [79..32]: salt (48 bits, free for extensions to distinguish pools sharing all other fields)
///   - [31]: discriminator (1 = concentrated, 0 = stableswap)
///   - concentrated: [30..23] tick spacing exponent (spacing is `1 << exp`), [22..0] reserved (must be 0)
///   - stableswap: [30..24] amplification factor, [23..0] center tick (scaled by 16, as before)
type PoolConfig is bytes32;

using {
    fee,
    salt,
    extension,
    isConcentrated,
    isStableswap,
    isFullRange,
    tickSpacingExp,
    concentratedTickSpacing,
    stableswapAmplification,
    stableswapCenterTick,
    stableswapActiveLiquidityTickRange,
    stableswapLiquidityWidth,
    validate,
    concentratedMaxLiquidityPerTick
} for PoolConfig global;

/// @notice Extracts the fee from a pool config
/// @param config The pool config
/// @return r The fee as a 0.16 number
function fee(PoolConfig config) pure returns (uint16 r) {
    assembly ("memory-safe") {
        r := and(shr(80, config), 0xffff)
    }
}

/// @notice Extracts the extension salt from a pool config
/// @param config The pool config
/// @return r The 48-bit salt
function salt(PoolConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(32, config), 0xffffffffffff)
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

/// @notice Checks if this is a concentrated liquidity pool
/// @param config The pool config
/// @return r True if the pool is concentrated liquidity
function isConcentrated(PoolConfig config) pure returns (bool r) {
    r = !config.isStableswap();
}

/// @notice Extracts the tick spacing exponent from a concentrated liquidity pool config
/// @dev Only valid for concentrated liquidity pools (isConcentrated() == true).
///   The tick spacing itself is always a power of two: `1 << exp`
/// @param config The pool config
/// @return r The tick spacing exponent (0-19)
function tickSpacingExp(PoolConfig config) pure returns (uint8 r) {
    assembly ("memory-safe") {
        // Extract bits 30-23
        r := and(shr(23, config), 0xff)
    }
}

/// @notice Extracts the tick spacing from a concentrated liquidity pool config
/// @dev Only valid for concentrated liquidity pools (isConcentrated() == true)
/// @param config The pool config
/// @return r The tick spacing, always a power of two
function concentratedTickSpacing(PoolConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        // spacing is 1 << exp
        r := shl(and(shr(23, config), 0xff), 1)
    }
}

/// @notice Checks if this is a stableswap pool
/// @param config The pool config
/// @return r True if the pool is stableswap
function isStableswap(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // = iff bit 31 is not set
        r := iszero(and(0x80000000, config))
    }
}

/// @notice Determines if this pool is full range (special case of stableswap with amplification=0 and center=0)
/// @dev Full range can be slightly optimized in that we don't need to compute the sqrt ratio at the tick boundaries
/// @param config The pool config
/// @return r True if the pool is full range
function isFullRange(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        // Full range when all 32 bits are 0 (discriminator=0, amplification=0, center=0)
        r := iszero(and(config, 0xffffffff))
    }
}

/// @notice Extracts the amplification factor from a stableswap pool config
/// @dev Only valid for stableswap pools (isStableswap() == true)
/// @param config The pool config
/// @return r The amplification factor (0-127)
function stableswapAmplification(PoolConfig config) pure returns (uint8 r) {
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
function stableswapCenterTick(PoolConfig config) pure returns (int32 r) {
    assembly ("memory-safe") {
        // Extract bits 23-0 and sign extend to 32 bits (24-bit signed integer)
        // Then multiply by 16, since the value does not have full precision
        r := mul(signextend(2, and(config, 0xffffff)), 16)
    }
}

/// @notice Returns the width of the liquidity range
function stableswapLiquidityWidth(PoolConfig config) pure returns (uint256 width) {
    uint8 amp = config.stableswapAmplification();

    assembly ("memory-safe") {
        width := shr(amp, MAX_TICK)
    }
}

/// @notice Computes the tick range where liquidity is active for stableswap pools
/// @param config The pool config
/// @return lower The lower tick of the bounds
/// @return upper The upper tick of the bounds
function stableswapActiveLiquidityTickRange(PoolConfig config) pure returns (int32 lower, int32 upper) {
    int32 center = config.stableswapCenterTick();
    uint256 width = config.stableswapLiquidityWidth();

    assembly ("memory-safe") {
        lower := sub(center, width)
        lower := add(lower, mul(sgt(MIN_TICK, lower), sub(MIN_TICK, lower)))

        upper := add(center, width)
        upper := sub(upper, mul(sgt(upper, MAX_TICK), sub(upper, MAX_TICK)))
    }
}

/// @notice Creates a PoolConfig for a concentrated liquidity pool
/// @param _fee The fee for the pool, as a 0.16 number
/// @param _tickSpacingExp The tick spacing exponent: spacing is `1 << _tickSpacingExp`, at most MAX_TICK_SPACING_EXP
/// @param _extension The extension address for the pool
/// @param _salt Free 48-bit salt distinguishing pools that share all other fields
/// @return c The packed configuration
function createConcentratedPoolConfig(uint16 _fee, uint8 _tickSpacingExp, address _extension, uint64 _salt)
    pure
    returns (PoolConfig c)
{
    assembly ("memory-safe") {
        // Set bit 31 to 1 for concentrated liquidity, then OR with the exponent in bits 30-23.
        // Bits 22-0 stay zero (reserved).
        let typeConfig := or(0x80000000, shl(23, and(_tickSpacingExp, 0xff)))
        c := or(
            or(shl(96, _extension), shl(80, and(_fee, 0xffff))),
            or(shl(32, and(_salt, 0xffffffffffff)), typeConfig)
        )
    }
}

/// @notice Creates a PoolConfig for a stableswap pool
/// @param _fee The fee for the pool, as a 0.16 number
/// @param _amplification The amplification factor (0-127)
/// @param _centerTick The center tick (will be divided by 16 and stored as 24-bit value)
/// @param _extension The extension address for the pool
/// @param _salt Free 48-bit salt distinguishing pools that share all other fields
/// @return c The packed configuration
function createStableswapPoolConfig(
    uint16 _fee,
    uint8 _amplification,
    int32 _centerTick,
    address _extension,
    uint64 _salt
) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // Divide center tick by 16 to get 24-bit representation
        let stableswapCenterTick24 := sdiv(_centerTick, 16)
        // Pack: bit 31 = 0 (stableswap), bits 30-24 = amplification, bits 23-0 = center tick
        let typeConfig := or(shl(24, and(_amplification, 0x7f)), and(stableswapCenterTick24, 0xffffff))
        c := or(
            or(shl(96, _extension), shl(80, and(_fee, 0xffff))),
            or(shl(32, and(_salt, 0xffffffffffff)), typeConfig)
        )
    }
}

/// @notice Creates a PoolConfig for a full range pool (stableswap with amplification=0, center=0)
/// @param _fee The fee for the pool, as a 0.16 number
/// @param _extension The extension address for the pool
/// @param _salt Free 48-bit salt distinguishing pools that share all other fields
/// @return c The packed configuration
function createFullRangePoolConfig(uint16 _fee, address _extension, uint64 _salt) pure returns (PoolConfig c) {
    assembly ("memory-safe") {
        // All 32 bits of type config are 0 (discriminator=0, amplification=0, center=0)
        c := or(or(shl(96, _extension), shl(80, and(_fee, 0xffff))), shl(32, and(_salt, 0xffffffffffff)))
    }
}

/// @notice Computes the maximum liquidity per tick for a given concentrated liquidity pool configuration.
/// @dev Only valid for concentrated liquidity pools. Stableswap pools don't use ticks.
/// @dev Calculated as type(uint128).max / (1 + (MAX_TICK_MAGNITUDE / tickSpacing) * 2)
/// @param config The concentrated liquidity pool configuration
/// @return maxLiquidity The maximum liquidity allowed to reference each tick
function concentratedMaxLiquidityPerTick(PoolConfig config) pure returns (uint128 maxLiquidity) {
    uint32 _tickSpacing = config.concentratedTickSpacing();

    assembly ("memory-safe") {
        // Calculate total number of usable ticks: 1 + (MAX_TICK_MAGNITUDE / tickSpacing) * 2
        // This represents all ticks from -MAX_TICK_MAGNITUDE to +MAX_TICK_MAGNITUDE, and tick 0
        // tickSpacing is a power of two, so the division is exact for the bound computation
        let numTicks := add(1, mul(div(MAX_TICK, _tickSpacing), 2))

        maxLiquidity := div(sub(shl(128, 1), 1), numTicks)
    }
}

/// @notice Thrown when tick spacing exponent exceeds the maximum allowed value
error InvalidTickSpacingExp();

/// @notice Thrown when the reserved low bits of a concentrated pool config are nonzero
error InvalidPoolConfigReservedBits();

/// @notice Thrown when tick spacing exceeds the maximum allowed value
error InvalidTickSpacing();

/// @notice Thrown when amplification factor exceeds the maximum allowed value
error InvalidStableswapAmplification();

/// @notice Thrown when center tick is not between min and max tick
error InvalidCenterTick();

/// @notice Validates that a pool config is properly formatted
/// @param config The config to validate
function validate(PoolConfig config) pure {
    if (config.isConcentrated()) {
        if (config.tickSpacingExp() > MAX_TICK_SPACING_EXP) {
            revert InvalidTickSpacingExp();
        }
        if ((PoolConfig.unwrap(config) & bytes32(uint256(0x7fffff))) != bytes32(0)) {
            revert InvalidPoolConfigReservedBits();
        }
    } else {
        // Stableswap pool: validate amplification factor <= 26
        if (config.stableswapAmplification() > 26) {
            revert InvalidStableswapAmplification();
        }
        int32 centerTick = config.stableswapCenterTick();
        if (centerTick < MIN_TICK || centerTick > MAX_TICK) {
            revert InvalidCenterTick();
        }
    }
}
