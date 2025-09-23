// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

/// @notice Unique identifier for a pool
/// @dev Wraps bytes32 to provide type safety for pool identifiers
type PoolId is bytes32;

using {toBytes32} for PoolId global;

/// @notice Converts a PoolId to its underlying bytes32 value
/// @param poolId The pool identifier to convert
/// @return The underlying bytes32 value
function toBytes32(PoolId poolId) pure returns (bytes32) {
    return PoolId.unwrap(poolId);
}
