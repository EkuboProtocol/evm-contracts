// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {MAX_TICK_SPACING, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {PoolId} from "./poolId.sol";

using {toPoolId, validatePoolKey, isFullRange, mustLoadFees, tickSpacing, fee, extension} for PoolKey global;

/// @notice Pool configuration packed into a single bytes32
/// @dev Contains extension address (20 bytes), fee (8 bytes), and tick spacing (4 bytes)
type Config is bytes32;

/// @notice Extracts the tick spacing from a pool key
/// @param pk The pool key
/// @return r The tick spacing
function tickSpacing(PoolKey memory pk) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(mload(add(64, pk)), 0xffffffff)
    }
}

/// @notice Extracts the fee from a pool key
/// @param pk The pool key
/// @return r The fee
function fee(PoolKey memory pk) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(mload(add(60, pk)), 0xffffffffffffffff)
    }
}

/// @notice Extracts the extension address from a pool key
/// @param pk The pool key
/// @return r The extension address
function extension(PoolKey memory pk) pure returns (address r) {
    assembly ("memory-safe") {
        r := and(mload(add(52, pk)), 0xffffffffffffffffffffffffffffffffffffffff)
    }
}

/// @notice Determines if fees must be loaded for swaps in this pool
/// @dev Returns true if either tick spacing or fee are nonzero
/// @param pk The pool key
/// @return r True if fees must be loaded
function mustLoadFees(PoolKey memory pk) pure returns (bool r) {
    assembly ("memory-safe") {
        // only if either of tick spacing and fee are nonzero
        // if _both_ are zero, then we know we do not need to load fees for swaps
        r := iszero(iszero(and(mload(add(64, pk)), 0xffffffffffffffffffffffff)))
    }
}

/// @notice Determines if this pool uses full-range-only tick spacing
/// @param pk The pool key
/// @return r True if the pool uses full-range-only tick spacing
function isFullRange(PoolKey memory pk) pure returns (bool r) {
    r = pk.tickSpacing() == FULL_RANGE_ONLY_TICK_SPACING;
}

/// @notice Creates a Config from individual components
/// @param _fee The fee for the pool
/// @param _tickSpacing The tick spacing for the pool
/// @param _extension The extension address for the pool
/// @return c The packed configuration
function toConfig(uint64 _fee, uint32 _tickSpacing, address _extension) pure returns (Config c) {
    assembly ("memory-safe") {
        c := add(add(shl(96, _extension), shl(32, _fee)), _tickSpacing)
    }
}

/// @notice Unique identifier for a pool containing token addresses and configuration
/// @dev Each pool has its own state associated with this key
struct PoolKey {
    /// @notice Address of token0 (must be < token1)
    address token0;
    /// @notice Address of token1 (must be > token0)
    address token1;
    /// @notice Packed configuration containing extension, fee, and tick spacing
    Config config;
}

/// @notice Thrown when tokens are not properly sorted (token0 >= token1)
error TokensMustBeSorted();

/// @notice Thrown when tick spacing exceeds the maximum allowed value
error InvalidTickSpacing();

/// @notice Validates that a pool key is properly formatted
/// @dev Checks that tokens are sorted and tick spacing is valid
/// @param key The pool key to validate
function validatePoolKey(PoolKey memory key) pure {
    if (key.token0 >= key.token1) revert TokensMustBeSorted();
    if (key.tickSpacing() > MAX_TICK_SPACING) {
        revert InvalidTickSpacing();
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
