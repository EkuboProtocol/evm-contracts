// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type MoneyMarketLiquidationState is bytes32;

using {activeOrderEndTime, liquidationAmount, parse} for MoneyMarketLiquidationState global;

function activeOrderEndTime(MoneyMarketLiquidationState state) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(state, 0xFFFFFFFFFFFFFFFF)
    }
}

function liquidationAmount(MoneyMarketLiquidationState state) pure returns (uint128 v) {
    assembly ("memory-safe") {
        v := and(shr(64, state), 0xffffffffffffffffffffffffffffffff)
    }
}

function parse(MoneyMarketLiquidationState state)
    pure
    returns (uint64 _activeOrderEndTime, uint128 _liquidationAmount)
{
    _activeOrderEndTime = state.activeOrderEndTime();
    _liquidationAmount = state.liquidationAmount();
}

function createMoneyMarketLiquidationState(uint64 _activeOrderEndTime, uint128 _liquidationAmount)
    pure
    returns (MoneyMarketLiquidationState state)
{
    assembly ("memory-safe") {
        state := or(_activeOrderEndTime, shl(64, _liquidationAmount))
    }
}
