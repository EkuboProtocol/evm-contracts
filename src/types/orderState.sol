// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

type OrderState is bytes32;

using {lastUpdateTime, saleRate, amountSold, parse} for OrderState global;

function lastUpdateTime(OrderState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

function saleRate(OrderState state) pure returns (uint112 rate) {
    assembly ("memory-safe") {
        rate := shr(144, shl(112, state))
    }
}

function amountSold(OrderState state) pure returns (uint112 amount) {
    assembly ("memory-safe") {
        amount := shr(144, state)
    }
}

function parse(OrderState state) pure returns (uint32 time, uint112 rate, uint112 amount) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(144, shl(112, state))
        amount := shr(144, state)
    }
}

function createOrderState(uint32 _lastUpdateTime, uint112 _saleRate, uint112 _amountSold) pure returns (OrderState s) {
    assembly ("memory-safe") {
        // s = (lastUpdateTime) | (saleRate << 32) | (amountSold << 144)
        s := or(
            or(and(_lastUpdateTime, 0xffffffff), shl(32, shr(144, shl(144, _saleRate)))),
            shl(144, shr(144, shl(144, _amountSold)))
        )
    }
}
