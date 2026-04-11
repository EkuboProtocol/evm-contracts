// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type MoneyMarketConfig is bytes32;

using {
    poolFee,
    borrowApyX32,
    ltvX32,
    twapDuration,
    liquidationDuration,
    minLiquidityMagnitude,
    parse
} for MoneyMarketConfig global;

function poolFee(MoneyMarketConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(config, 0xFFFFFFFFFFFFFFFF)
    }
}

function borrowApyX32(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(64, config), 0xFFFFFFFF)
    }
}

function ltvX32(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(96, config), 0xFFFFFFFF)
    }
}

function twapDuration(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(128, config), 0xFFFFFFFF)
    }
}

function liquidationDuration(MoneyMarketConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(160, config), 0xFFFFFFFF)
    }
}

function minLiquidityMagnitude(MoneyMarketConfig config) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(shr(192, config), 0xFF)
    }
}

function parse(MoneyMarketConfig config)
    pure
    returns (
        uint64 _poolFee,
        uint32 _borrowApyX32,
        uint32 _ltvX32,
        uint32 _twapDuration,
        uint32 _liquidationDuration,
        uint8 _minLiquidityMagnitude
    )
{
    _poolFee = config.poolFee();
    _borrowApyX32 = config.borrowApyX32();
    _ltvX32 = config.ltvX32();
    _twapDuration = config.twapDuration();
    _liquidationDuration = config.liquidationDuration();
    _minLiquidityMagnitude = config.minLiquidityMagnitude();
}

function createMoneyMarketConfig(
    uint64 _poolFee,
    uint32 _borrowApyX32,
    uint32 _ltvX32,
    uint32 _twapDuration,
    uint32 _liquidationDuration,
    uint8 _minLiquidityMagnitude
) pure returns (MoneyMarketConfig config) {
    assembly ("memory-safe") {
        config := or(
            or(
                or(or(_poolFee, shl(64, _borrowApyX32)), shl(96, _ltvX32)),
                or(shl(128, _twapDuration), shl(160, _liquidationDuration))
            ),
            shl(192, _minLiquidityMagnitude)
        )
    }
}
