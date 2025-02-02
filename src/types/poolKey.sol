// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MAX_TICK_SPACING} from "../math/constants.sol";

using {toPoolId, validatePoolKey} for PoolKey global;

// Each pool has its own state associated with this key
struct PoolKey {
    address token0;
    address token1;
    uint128 fee;
    uint32 tickSpacing;
    address extension;
}

error TokensMustBeSorted();
error InvalidTickSpacing();

function validatePoolKey(PoolKey memory key) pure {
    if (key.token0 >= key.token1) revert TokensMustBeSorted();
    if (key.tickSpacing == 0 || key.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
}

function toPoolId(PoolKey memory key) pure returns (bytes32 result) {
    assembly ("memory-safe") {
        // it's already copied into memory
        result := keccak256(key, 160)
    }
}
