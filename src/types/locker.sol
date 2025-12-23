// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type Locker is bytes32;

using {id, addr, parse} for Locker global;

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

function parse(Locker locker) pure returns (uint256 lockerId, address lockerAddr) {
    assembly ("memory-safe") {
        lockerId := sub(shr(160, locker), 1)
        lockerAddr := shr(96, shl(96, locker))
    }
}
