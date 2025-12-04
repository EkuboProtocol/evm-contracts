// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {SqrtRatio} from "./sqrtRatio.sol";

type PoolState is bytes32;

using {sqrtRatio, tick, liquidity, isInitialized, parse} for PoolState global;

function sqrtRatio(PoolState state) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        r := shr(160, state)
    }
}

function tick(PoolState state) pure returns (int32 t) {
    assembly ("memory-safe") {
        t := signextend(3, shr(128, state))
    }
}

function liquidity(PoolState state) pure returns (uint128 l) {
    assembly ("memory-safe") {
        l := shr(128, shl(128, state))
    }
}

function isInitialized(PoolState state) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := iszero(iszero(state))
    }
}

function parse(PoolState state) pure returns (SqrtRatio r, int32 t, uint128 l) {
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
