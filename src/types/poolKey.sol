// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {PoolId} from "./poolId.sol";
import {PoolConfig} from "./poolConfig.sol";

using {toPoolId, validate} for PoolKey global;

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

/// @notice Validates that a pool key is valid
/// @dev Checks that tokens are sorted and the config is valid
/// @param key The pool key to validate
function validate(PoolKey memory key) pure {
    if (key.token0 >= key.token1) revert TokensMustBeSorted();
    key.config.validate();
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
