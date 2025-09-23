// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

type Locker is bytes32;

using {id, addr} for Locker global;

function id(Locker locker) pure returns (uint256 v) {
    assembly ("memory-safe") {
        v := sub(shr(160, locker), 1)
    }
}

function addr(Locker locker) pure returns (address v) {
    assembly ("memory-safe") {
        v := shr(96, shl(96, locker))
    }
}
