// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {SqrtRatio} from "./sqrtRatio.sol";

type PoolState is bytes32;

using {sqrtRatio, tick, liquidity, isInitialized, parse} for PoolState global;

function sqrtRatio(PoolState state) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        r := shr(160, state)
    }
}

/// @notice Extracts the tick from a pool state
/// @param state The pool state
/// @return t The tick value, bounded by int32
function tick(PoolState state) pure returns (int256 t) {
    assembly ("memory-safe") {
        t := signextend(3, shr(128, state))
    }
}

/// @notice Extracts the liquidity from a pool state
/// @param state The pool state
/// @return l The liquidity value, bounded by uint128
function liquidity(PoolState state) pure returns (uint256 l) {
    assembly ("memory-safe") {
        l := shr(128, shl(128, state))
    }
}

function isInitialized(PoolState state) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := state
    }
}

/// @notice Parses all components from a pool state
/// @param state The pool state
/// @return r The sqrt ratio
/// @return t The tick value, bounded by int32
/// @return l The liquidity value, bounded by uint128
function parse(PoolState state) pure returns (SqrtRatio r, int256 t, uint256 l) {
    assembly ("memory-safe") {
        r := shr(160, state)
        t := signextend(3, shr(128, state))
        l := shr(128, shl(128, state))
    }
}

function createPoolState(SqrtRatio _sqrtRatio, int32 _tick, uint128 _liquidity) pure returns (PoolState s) {
    assembly ("memory-safe") {
        // s = (sqrtRatio << 160) | (_tick << 128) | liquidity
        s := or(shl(160, _sqrtRatio), or(shl(128, and(_tick, 0xFFFFFFFF)), shr(128, shl(128, _liquidity))))
    }
}
