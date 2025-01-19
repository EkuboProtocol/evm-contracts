// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {NATIVE_TOKEN_ADDRESS, UpdatePositionParameters, SwapParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../../src/math/ticks.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle} from "../../src/extensions/Oracle.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";

contract OracleTest is FullTest {
    Oracle oracle;

    function setUp() public override {
        FullTest.setUp();
        address deployAddress = address(
            uint160(
                CallPoints({
                    beforeInitializePool: true,
                    afterInitializePool: false,
                    beforeUpdatePosition: true,
                    afterUpdatePosition: false,
                    beforeSwap: true,
                    afterSwap: false,
                    beforeCollectFees: false,
                    afterCollectFees: false
                }).toUint8()
            ) << 152
        );
        deployCodeTo("Oracle.sol", abi.encode(core, NATIVE_TOKEN_ADDRESS), deployAddress);
        oracle = Oracle(deployAddress);
    }

    function advanceTime(uint32 by) internal {
        vm.warp(vm.getBlockTimestamp() + by);
    }

    function test_getImmutables() public view {
        assertEq(oracle.oracleToken(), NATIVE_TOKEN_ADDRESS);
        assertEq(oracle.timestampOffset(), uint64(block.timestamp));
    }

    function test_createPool_beforeInitializePool() public {
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, 0, MAX_TICK_SPACING, address(oracle));
        assertEq(oracle.snapshotCount(address(token1)), 1);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 0);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);
    }

    function test_createPool_beforeInitializePool_reverts() public {
        vm.expectRevert(Oracle.PairsWithOracleTokenOnly.selector);
        createPool(address(token0), address(token1), 0, 0, MAX_TICK_SPACING, address(oracle));

        vm.expectRevert(Oracle.TickSpacingMustBeMaximum.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, 0, MAX_TICK_SPACING - 1, address(oracle));

        vm.expectRevert(Oracle.FeeMustBeZero.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, 1, MAX_TICK_SPACING, address(oracle));
    }

    function test_createPosition_failsForSmallerPosition() public {
        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));
    }

    function test_createPosition() public {
        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        advanceTime(30);

        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);
        (uint256 id, uint128 liquidity) = createPosition(poolKey, bounds, 100, 200);
        assertEq(oracle.snapshotCount(address(token1)), 2);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 1);
        assertEq(secondsSinceOffset, 30);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 30 * 693147);

        advanceTime(45);
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity, address(this), 0, 0);
        assertEq(amount0, 99);
        assertEq(amount1, 199);

        assertEq(oracle.snapshotCount(address(token1)), 3);
        (secondsSinceOffset, secondsPerLiquidityCumulative, tickCumulative) = oracle.snapshots(address(token1), 2);
        assertEq(secondsSinceOffset, 75);
        assertEq(secondsPerLiquidityCumulative, (45 << 128) / liquidity);
        assertEq(tickCumulative, 75 * 693147);
    }

    function test_cannotCallExtensionMethodsDirectly() public {
        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeInitializePool(address(0), poolKey, 0);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeUpdatePosition(address(0), poolKey, UpdatePositionParameters(bytes32(0x0), Bounds(-100, 100), 0));

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeSwap(address(0), poolKey, SwapParameters(0, false, 0, 0));
    }

    receive() external payable {}
}
