// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {
    MAX_TICK,
    MIN_TICK,
    STABLESWAP_POOL_TYPE_FLAG,
    STABLESWAP_CENTER_TICK_MASK,
    STABLESWAP_AMPLIFICATION_SHIFT
} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Pool configuration packed into a single bytes32
/// @dev Contains extension address (20 bytes), fee (8 bytes), and tick spacing (4 bytes)
type PoolConfig is bytes32;

using {
    tickSpacing,
    fee,
    extension,
    maxLiquidityPerTickConcentratedLiquidity,
    isStableswap,
    stableswapCenterTick,
    stableswapAmplification,
    stableswapTradingRange
} for PoolConfig global;

/// @notice Extracts the tick spacing from a pool config
/// @dev For stableswap pools, this returns the raw encoded value (not actual tick spacing)
/// @param config The pool config
/// @return r The tick spacing (or encoded stableswap parameters)
function tickSpacing(PoolConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(config, 0xffffffff)
    }
}

/// @notice Checks if a pool config represents a stableswap pool
/// @param config The pool config
/// @return r True if this is a stableswap pool
function isStableswap(PoolConfig config) pure returns (bool r) {
    assembly ("memory-safe") {
        r := iszero(iszero(and(config, STABLESWAP_POOL_TYPE_FLAG)))
    }
}

/// @notice Extracts the center tick from a stableswap pool config
/// @dev Only valid for stableswap pools (when isStableswap returns true)
/// @param config The pool config
/// @return r The center tick (signed 28-bit value)
function stableswapCenterTick(PoolConfig config) pure returns (int32 r) {
    unchecked {
        // Extract lower 28 bits
        uint256 raw = uint256(PoolConfig.unwrap(config)) & STABLESWAP_CENTER_TICK_MASK;
        // Shift left by 4 to move bit 27 to bit 31
        uint256 shifted = raw << 4;
        // Cast to int32 for arithmetic right shift
        int32 temp = int32(uint32(shifted));
        // Arithmetic right shift by 4 to sign-extend
        r = temp >> 4;
    }
}

/// @notice Extracts the amplification factor from a stableswap pool config
/// @dev Only valid for stableswap pools (when isStableswap returns true)
/// @param config The pool config
/// @return r The amplification factor (0-7)
function stableswapAmplification(PoolConfig config) pure returns (uint8 r) {
    assembly ("memory-safe") {
        r := and(shr(STABLESWAP_AMPLIFICATION_SHIFT, config), 0x7)
    }
}

/// @notice Calculates the trading range for a stableswap pool
/// @dev The range is centered around the center tick with width determined by amplification
/// @param config The pool config
/// @return minTick The minimum tick for trading
/// @return maxTick The maximum tick for trading
function stableswapTradingRange(PoolConfig config) pure returns (int32 minTick, int32 maxTick) {
    int32 centerTick = config.stableswapCenterTick();
    uint8 amplification = config.stableswapAmplification();

    // Liquidity multiplier is 2^amplification
    // Higher amplification = more concentrated = smaller range
    // We'll use a formula where the range decreases exponentially with amplification
    // Range = MAX_TICK_MAGNITUDE / (2^amplification)

    unchecked {
        // Calculate half-range: MAX_TICK_MAGNITUDE >> amplification
        int32 halfRange = int32(uint32(MAX_TICK) >> amplification);

        // Calculate min and max ticks, clamping to valid range
        int256 minTickCalc = int256(centerTick) - int256(halfRange);
        int256 maxTickCalc = int256(centerTick) + int256(halfRange);

        minTick = int32(FixedPointMathLib.max(minTickCalc, int256(MIN_TICK)));
        maxTick = int32(FixedPointMathLib.min(maxTickCalc, int256(MAX_TICK)));
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

/// @notice Creates a PoolConfig for a stableswap pool
/// @param _fee The fee for the pool
/// @param _centerTick The center tick around which liquidity is concentrated
/// @param _amplification The amplification factor (0-7), where liquidity multiplier = 2^amplification
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function createStableswapPoolConfig(uint64 _fee, int32 _centerTick, uint8 _amplification, address _extension)
    pure
    returns (PoolConfig c)
{
    assembly ("memory-safe") {
        // Encode stableswap parameters:
        // - bits 0-27: center tick (sign-extended)
        // - bits 28-30: amplification factor
        // - bit 31: stableswap flag (1)

        // First, ensure _centerTick is properly sign-extended to 32 bits, then mask to 28 bits
        let centerTick32 := signextend(3, _centerTick)
        let centerTickEncoded := and(centerTick32, STABLESWAP_CENTER_TICK_MASK)
        let amplificationEncoded := shl(STABLESWAP_AMPLIFICATION_SHIFT, and(_amplification, 0x7))
        let stableswapConfig := or(or(centerTickEncoded, amplificationEncoded), STABLESWAP_POOL_TYPE_FLAG)

        c :=
            add(
                add(
                    shl(96, and(_extension, 0xffffffffffffffffffffffffffffffffffffffff)),
                    shl(32, and(_fee, 0xffffffffffffffff))
                ),
                stableswapConfig
            )
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
