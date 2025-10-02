// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type StorageSlot is bytes32;

using {load, store, storeTwo, next, add} for StorageSlot global;

function load(StorageSlot slot) view returns (bytes32 value) {
    assembly ("memory-safe") {
        value := sload(slot)
    }
}

function store(StorageSlot slot, bytes32 value) {
    assembly ("memory-safe") {
        sstore(slot, value)
    }
}

function storeTwo(StorageSlot slot, bytes32 value0, bytes32 value1) {
    assembly ("memory-safe") {
        sstore(slot, value0)
        sstore(add(slot, 1), value1)
    }
}

function next(StorageSlot slot) pure returns (StorageSlot nextSlot) {
    assembly ("memory-safe") {
        nextSlot := add(slot, 1)
    }
}

function add(StorageSlot slot, uint256 addend) pure returns (StorageSlot summedSlot) {
    assembly ("memory-safe") {
        summedSlot := add(slot, addend)
    }
}
