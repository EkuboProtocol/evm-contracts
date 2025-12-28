// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolConfig, createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {MAX_TICK_MAGNITUDE} from "../src/math/constants.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TestToken} from "./TestToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

contract MaxLiquidityPerTickTest is Test {
    using CoreLib for ICore;

    Core core;
    Positions positions;
    TestToken token0;
    TestToken token1;

    function setUp() public {
        core = new Core();
        positions = new Positions(core, address(this), 0, 0);
        token0 = new TestToken(address(this));
        token1 = new TestToken(address(this));

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
    }

    function test_maxLiquidityPerTick_calculation() public pure {
        // Test with tick spacing of 1
        PoolConfig config1 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 1, _extension: address(0)});
        uint256 numTicks1 = 1 + (MAX_TICK_MAGNITUDE / 1) * 2;
        uint128 expected1 = uint128(type(uint128).max / numTicks1);
        assertEq(config1.concentratedMaxLiquidityPerTick(), expected1, "tick spacing 1");

        // Test with tick spacing of 10
        PoolConfig config10 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 10, _extension: address(0)});
        uint256 numTicks10 = 1 + (MAX_TICK_MAGNITUDE / 10) * 2;
        uint128 expected10 = uint128(type(uint128).max / numTicks10);
        assertEq(config10.concentratedMaxLiquidityPerTick(), expected10, "tick spacing 10");

        // Test with tick spacing of 100
        PoolConfig config100 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 100, _extension: address(0)});
        uint256 numTicks100 = 1 + (MAX_TICK_MAGNITUDE / 100) * 2;
        uint128 expected100 = uint128(type(uint128).max / numTicks100);
        assertEq(config100.concentratedMaxLiquidityPerTick(), expected100, "tick spacing 100");
    }

    function test_maxLiquidityPerTick_increases_with_concentratedTickSpacing() public pure {
        // Larger tick spacing should allow more liquidity per tick
        PoolConfig config1 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 1, _extension: address(0)});
        PoolConfig config10 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 10, _extension: address(0)});
        PoolConfig config100 = createConcentratedPoolConfig({_fee: 0, _tickSpacing: 100, _extension: address(0)});

        uint128 max1 = config1.concentratedMaxLiquidityPerTick();
        uint128 max10 = config10.concentratedMaxLiquidityPerTick();
        uint128 max100 = config100.concentratedMaxLiquidityPerTick();

        assertTrue(max10 > max1, "max10 > max1");
        assertTrue(max100 > max10, "max100 > max10");
    }
}
