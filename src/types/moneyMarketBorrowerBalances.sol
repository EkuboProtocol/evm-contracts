// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type MoneyMarketBorrowerBalances is bytes32;

using {collateralAmount, debtAmount, parse} for MoneyMarketBorrowerBalances global;

function collateralAmount(MoneyMarketBorrowerBalances balances) pure returns (uint128 v) {
    assembly ("memory-safe") {
        v := shr(128, balances)
    }
}

function debtAmount(MoneyMarketBorrowerBalances balances) pure returns (uint128 v) {
    assembly ("memory-safe") {
        v := and(balances, 0xffffffffffffffffffffffffffffffff)
    }
}

function parse(MoneyMarketBorrowerBalances balances) pure returns (uint128 _collateralAmount, uint128 _debtAmount) {
    _collateralAmount = balances.collateralAmount();
    _debtAmount = balances.debtAmount();
}

function createMoneyMarketBorrowerBalances(uint128 _collateralAmount, uint128 _debtAmount)
    pure
    returns (MoneyMarketBorrowerBalances balances)
{
    assembly ("memory-safe") {
        balances := or(shl(128, _collateralAmount), _debtAmount)
    }
}
