// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type PoolBalanceUpdate is bytes32;

using {delta0, delta1, parse} for PoolBalanceUpdate global;

function delta0(PoolBalanceUpdate update) pure returns (int128 _delta0) {
    assembly ("memory-safe") {
        _delta0 := signextend(15, update)
    }
}

function delta1(PoolBalanceUpdate update) pure returns (int128 _delta1) {
    assembly ("memory-safe") {
        _delta1 := signextend(15, shr(128, update))
    }
}

function parse(PoolBalanceUpdate update) pure returns (int128 _delta0, int128 _delta1) {
    assembly ("memory-safe") {
        _delta0 := signextend(15, update)
        _delta1 := signextend(15, shr(128, update))
    }
}

function createPoolBalanceUpdate(int128 _delta0, int128 _delta1) pure returns (PoolBalanceUpdate update) {
    assembly ("memory-safe") {
        // update = (delta1 << 128) | delta0
        update := or(shl(128, _delta1), and(_delta0, 0xffffffffffffffffffffffffffffffff))
    }
}
