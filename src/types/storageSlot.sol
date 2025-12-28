// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type StorageSlot is bytes32;

using {load, loadTwo, store, storeTwo, next, add, sub} for StorageSlot global;

function load(StorageSlot slot) view returns (bytes32 value) {
    assembly ("memory-safe") {
        value := sload(slot)
    }
}

function loadTwo(StorageSlot slot) view returns (bytes32 value0, bytes32 value1) {
    value0 = slot.load();
    value1 = slot.next().load();
}

function store(StorageSlot slot, bytes32 value) {
    assembly ("memory-safe") {
        sstore(slot, value)
    }
}

function storeTwo(StorageSlot slot, bytes32 value0, bytes32 value1) {
    slot.store(value0);
    slot.next().store(value1);
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

function sub(StorageSlot slot, uint256 subtrahend) pure returns (StorageSlot differenceSlot) {
    assembly ("memory-safe") {
        differenceSlot := sub(slot, subtrahend)
    }
}
