// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

type TickInfo is bytes32;

using {liquidityDelta, liquidityNet, parse} for TickInfo global;

function liquidityDelta(TickInfo info) pure returns (int128 delta) {
    assembly ("memory-safe") {
        delta := signextend(15, shr(128, info))
    }
}

function liquidityNet(TickInfo info) pure returns (uint128 net) {
    assembly ("memory-safe") {
        net := shr(128, shl(128, info))
    }
}

function parse(TickInfo info) pure returns (int128 delta, uint128 net) {
    assembly ("memory-safe") {
        delta := signextend(15, shr(128, info))
        net := shr(128, shl(128, info))
    }
}

function createTickInfo(int128 _liquidityDelta, uint128 _liquidityNet) pure returns (TickInfo info) {
    assembly ("memory-safe") {
        // info = (liquidityDelta << 128) | liquidityNet
        info :=
            or(shl(128, and(_liquidityDelta, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)), shr(128, shl(128, _liquidityNet)))
    }
}
