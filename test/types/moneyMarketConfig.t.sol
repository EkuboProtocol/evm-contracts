// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {MoneyMarketConfig, createMoneyMarketConfig} from "../../src/types/moneyMarketConfig.sol";

contract MoneyMarketConfigTest is Test {
    function test_conversionToAndFrom(MoneyMarketConfig config) public pure {
        MoneyMarketConfig roundtrip = createMoneyMarketConfig({
            _poolFee: config.poolFee(),
            _borrowApyX32: config.borrowApyX32(),
            _ltvX32: config.ltvX32(),
            _twapDuration: config.twapDuration(),
            _liquidationDuration: config.liquidationDuration(),
            _minLiquidityMagnitude: config.minLiquidityMagnitude()
        });
        assertEq(roundtrip.poolFee(), config.poolFee());
        assertEq(roundtrip.borrowApyX32(), config.borrowApyX32());
        assertEq(roundtrip.ltvX32(), config.ltvX32());
        assertEq(roundtrip.twapDuration(), config.twapDuration());
        assertEq(roundtrip.liquidationDuration(), config.liquidationDuration());
        assertEq(roundtrip.minLiquidityMagnitude(), config.minLiquidityMagnitude());
    }

    function test_conversionFromAndTo(
        uint64 _poolFee,
        uint32 _borrowApyX32,
        uint32 _ltvX32,
        uint32 _twapDuration,
        uint32 _liquidationDuration,
        uint8 _minLiquidityMagnitude
    ) public pure {
        MoneyMarketConfig config = createMoneyMarketConfig({
            _poolFee: _poolFee,
            _borrowApyX32: _borrowApyX32,
            _ltvX32: _ltvX32,
            _twapDuration: _twapDuration,
            _liquidationDuration: _liquidationDuration,
            _minLiquidityMagnitude: _minLiquidityMagnitude
        });
        assertEq(config.poolFee(), _poolFee);
        assertEq(config.borrowApyX32(), _borrowApyX32);
        assertEq(config.ltvX32(), _ltvX32);
        assertEq(config.twapDuration(), _twapDuration);
        assertEq(config.liquidationDuration(), _liquidationDuration);
        assertEq(config.minLiquidityMagnitude(), _minLiquidityMagnitude);
    }

    function test_parse(
        uint64 _poolFee,
        uint32 _borrowApyX32,
        uint32 _ltvX32,
        uint32 _twapDuration,
        uint32 _liquidationDuration,
        uint8 _minLiquidityMagnitude
    ) public pure {
        MoneyMarketConfig config = createMoneyMarketConfig({
            _poolFee: _poolFee,
            _borrowApyX32: _borrowApyX32,
            _ltvX32: _ltvX32,
            _twapDuration: _twapDuration,
            _liquidationDuration: _liquidationDuration,
            _minLiquidityMagnitude: _minLiquidityMagnitude
        });

        (uint64 poolFee, uint32 borrowApy, uint32 ltv, uint32 twap, uint32 liquidation, uint8 minLiquidityMag) =
            config.parse();

        assertEq(poolFee, _poolFee);
        assertEq(borrowApy, _borrowApyX32);
        assertEq(ltv, _ltvX32);
        assertEq(twap, _twapDuration);
        assertEq(liquidation, _liquidationDuration);
        assertEq(minLiquidityMag, _minLiquidityMagnitude);
    }
}
