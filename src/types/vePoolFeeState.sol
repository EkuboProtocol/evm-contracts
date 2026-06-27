// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type VePoolFeeState is bytes32;

using {feeWeightSum, swapFee, parse} for VePoolFeeState global;

function feeWeightSum(VePoolFeeState state) pure returns (uint192 sum) {
    assembly ("memory-safe") {
        sum := state
    }
}

function swapFee(VePoolFeeState state) pure returns (uint64 fee) {
    assembly ("memory-safe") {
        fee := shr(192, state)
    }
}

function parse(VePoolFeeState state) pure returns (uint192 sum, uint64 fee) {
    assembly ("memory-safe") {
        sum := state
        fee := shr(192, state)
    }
}

function createVePoolFeeState(uint192 feeWeightSum_, uint64 swapFee_) pure returns (VePoolFeeState state) {
    assembly ("memory-safe") {
        state := or(
            and(feeWeightSum_, 0xffffffffffffffffffffffffffffffffffffffffffffffff),
            shl(192, and(swapFee_, 0xffffffffffffffff))
        )
    }
}
