// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type VePoolSwapFeeState is bytes32;

using {totalWeight, swapFee, parse} for VePoolSwapFeeState global;

function totalWeight(VePoolSwapFeeState state) pure returns (uint128 weight) {
    assembly ("memory-safe") {
        weight := and(state, 0xffffffffffffffffffffffffffffffff)
    }
}

function swapFee(VePoolSwapFeeState state) pure returns (uint64 fee) {
    assembly ("memory-safe") {
        fee := and(shr(128, state), 0xffffffffffffffff)
    }
}

function parse(VePoolSwapFeeState state) pure returns (uint128 weight, uint64 fee) {
    assembly ("memory-safe") {
        weight := and(state, 0xffffffffffffffffffffffffffffffff)
        fee := and(shr(128, state), 0xffffffffffffffff)
    }
}

function createVePoolSwapFeeState(uint128 totalWeight_, uint64 swapFee_) pure returns (VePoolSwapFeeState state) {
    assembly ("memory-safe") {
        state := or(and(totalWeight_, 0xffffffffffffffffffffffffffffffff), shl(128, and(swapFee_, 0xffffffffffffffff)))
    }
}
