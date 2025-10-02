// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type StorageSlot is bytes32;

using {load, store, storeTwo, storeTwoBool, next, addUint, addBool} for StorageSlot global;

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

function storeTwoBool(StorageSlot slot, bool value0, bool value1) {
    bytes32 v0;
    bytes32 v1;
    assembly ("memory-safe") {
        v0 := value0
        v1 := value1
    }
    slot.storeTwo(v0, v1);
}

function next(StorageSlot slot) pure returns (StorageSlot nextSlot) {
    assembly ("memory-safe") {
        nextSlot := add(slot, 1)
    }
}

function addUint(StorageSlot slot, uint256 addend) pure returns (StorageSlot summedSlot) {
    assembly ("memory-safe") {
        summedSlot := add(slot, addend)
    }
}

function addBool(StorageSlot slot, bool addend) pure returns (StorageSlot summedSlot) {
    assembly ("memory-safe") {
        summedSlot := add(slot, addend)
    }
}
