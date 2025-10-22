// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

type PoolBalanceUpdate is bytes32;

using {delta0, delta1} for PoolBalanceUpdate global;

function delta0(PoolBalanceUpdate update) pure returns (int128 v) {
    assembly ("memory-safe") {
        v := signextend(15, shr(128, update))
    }
}

function delta1(PoolBalanceUpdate update) pure returns (int128 v) {
    assembly ("memory-safe") {
        v := signextend(15, update)
    }
}

function createPoolBalanceUpdate(int128 _delta0, int128 _delta1) pure returns (PoolBalanceUpdate update) {
    assembly ("memory-safe") {
        // update = (delta0 << 128) | delta1
        update := or(shl(128, _delta0), and(_delta1, 0xffffffffffffffffffffffffffffffff))
    }
}
