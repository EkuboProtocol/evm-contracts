// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

type TwammPoolState is bytes32;

using {
    lastVirtualOrderExecutionTime,
    realLastVirtualOrderExecutionTime,
    saleRateToken0,
    saleRateToken1,
    parse
} for TwammPoolState global;

function lastVirtualOrderExecutionTime(TwammPoolState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

function realLastVirtualOrderExecutionTime(TwammPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

function saleRateToken0(TwammPoolState state) pure returns (uint112 rate) {
    assembly ("memory-safe") {
        rate := shr(144, shl(112, state))
    }
}

function saleRateToken1(TwammPoolState state) pure returns (uint112 rate) {
    assembly ("memory-safe") {
        rate := shr(144, state)
    }
}

function parse(TwammPoolState state) pure returns (uint32 time, uint112 rate0, uint112 rate1) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate0 := shr(144, shl(112, state))
        rate1 := shr(144, state)
    }
}

function createTwammPoolState(uint32 _lastVirtualOrderExecutionTime, uint112 _saleRateToken0, uint112 _saleRateToken1)
    pure
    returns (TwammPoolState s)
{
    assembly ("memory-safe") {
        // s = (lastVirtualOrderExecutionTime) | (saleRateToken0 << 32) | (saleRateToken1 << 144)
        s := or(
            or(and(_lastVirtualOrderExecutionTime, 0xffffffff), shr(112, shl(144, _saleRateToken0))),
            shl(144, _saleRateToken1)
        )
    }
}
