// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type MoneyMarketConfig is bytes32;

using {ltvX32, twapDuration, liquidationDuration, minLiquidityMagnitude, parse} for MoneyMarketConfig global;

function ltvX32(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(config, 0xFFFFFFFF)
    }
}

function twapDuration(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(32, config), 0xFFFFFFFF)
    }
}

function liquidationDuration(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(64, config), 0xFFFFFFFF)
    }
}

function minLiquidityMagnitude(MoneyMarketConfig config) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(shr(96, config), 0xFF)
    }
}

function parse(MoneyMarketConfig config)
    pure
    returns (uint32 _ltvX32, uint32 _twapDuration, uint32 _liquidationDuration, uint8 _minLiquidityMagnitude)
{
    _ltvX32 = config.ltvX32();
    _twapDuration = config.twapDuration();
    _liquidationDuration = config.liquidationDuration();
    _minLiquidityMagnitude = config.minLiquidityMagnitude();
}

function createMoneyMarketConfig(
    uint32 _ltvX32,
    uint32 _twapDuration,
    uint32 _liquidationDuration,
    uint8 _minLiquidityMagnitude
) pure returns (MoneyMarketConfig config) {
    assembly ("memory-safe") {
        config := or(
            or(or(_ltvX32, shl(32, _twapDuration)), shl(64, _liquidationDuration)),
            shl(96, _minLiquidityMagnitude)
        )
    }
}
