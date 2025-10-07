// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MAX_TICK_SPACING, MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {PoolId} from "./poolId.sol";
import {PoolConfig} from "./poolConfig.sol";

using {toPoolId, validatePoolKey, isStableswap, mustLoadFees, tickSpacing, fee, extension} for PoolKey global;

/// @notice Extracts the tick spacing from a pool key
/// @param pk The pool key
/// @return r The tick spacing
function tickSpacing(PoolKey memory pk) pure returns (uint32 r) {
    return pk.config.tickSpacing();
}

/// @notice Extracts the fee from a pool key
/// @param pk The pool key
/// @return r The fee
function fee(PoolKey memory pk) pure returns (uint64 r) {
    return pk.config.fee();
}

/// @notice Extracts the extension address from a pool key
/// @param pk The pool key
/// @return r The extension address
function extension(PoolKey memory pk) pure returns (address r) {
    return pk.config.extension();
}

/// @notice Determines if fees must be loaded for swaps in this pool
/// @dev Returns true if either the config lower 32 bits or fee are nonzero
/// @param pk The pool key
/// @return r True if fees must be loaded
function mustLoadFees(PoolKey memory pk) pure returns (bool r) {
    assembly ("memory-safe") {
        // only if either of config lower 32 bits and fee are nonzero
        // if _both_ are zero, then we know we do not need to load fees for swaps
        r := iszero(iszero(and(mload(add(64, pk)), 0xffffffffffffffffffffffff)))
    }
}

/// @notice Determines if this pool is a stableswap pool
/// @param pk The pool key
/// @return r True if the pool is a stableswap pool
function isStableswap(PoolKey memory pk) pure returns (bool r) {
    r = pk.config.isStableswap();
}

/// @notice Unique identifier for a pool containing token addresses and configuration
/// @dev Each pool has its own state associated with this key
struct PoolKey {
    /// @notice Address of token0 (must be < token1)
    address token0;
    /// @notice Address of token1 (must be > token0)
    address token1;
    /// @notice Packed configuration containing extension, fee, and tick spacing
    PoolConfig config;
}

/// @notice Thrown when tokens are not properly sorted (token0 >= token1)
error TokensMustBeSorted();

/// @notice Thrown when tick spacing exceeds the maximum allowed value
error InvalidTickSpacing();

/// @notice Thrown when stableswap center tick is outside valid range
error InvalidStableswapCenterTick();

/// @notice Validates that a pool key is properly formatted
/// @dev Checks that tokens are sorted and tick spacing is valid
/// @param key The pool key to validate
function validatePoolKey(PoolKey memory key) pure {
    if (key.token0 >= key.token1) revert TokensMustBeSorted();

    if (key.config.isStableswap()) {
        // For stableswap pools, validate the center tick is within bounds
        int32 centerTick = key.config.stableswapCenterTick();
        if (centerTick < MIN_TICK || centerTick > MAX_TICK) {
            revert InvalidStableswapCenterTick();
        }
    } else {
        // For regular pools, validate tick spacing
        if (key.tickSpacing() > MAX_TICK_SPACING) {
            revert InvalidTickSpacing();
        }
    }
}

/// @notice Converts a pool key to a unique pool ID
/// @param key The pool key
/// @return result The unique pool ID (hash of the pool key)
function toPoolId(PoolKey memory key) pure returns (PoolId result) {
    assembly ("memory-safe") {
        // it's already copied into memory
        result := keccak256(key, 96)
    }
}
