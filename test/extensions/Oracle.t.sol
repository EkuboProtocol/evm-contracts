// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core} from "../../src/Core.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {Positions, ITokenURIGenerator} from "../../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../../src/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey, Bounds} from "../../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../../src/math/ticks.sol";
import {LibString} from "solady/utils/LibString.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TestToken} from "../TestToken.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle, MAX_TICK_AT_MAX_TICK_SPACING} from "../../src/extensions/Oracle.sol";
import {toUint8} from "../../src/types/callPoints.sol";
import {ETH_ADDRESS} from "../../src/base/TransfersTokens.sol";

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
        deployCodeTo("Oracle.sol", abi.encode(core, ETH_ADDRESS), deployAddress);
        oracle = Oracle(deployAddress);
    }

    function advanceTime(uint32 by) internal {
        vm.warp(vm.getBlockTimestamp() + by);
    }

    function test_getImmutables() public view {
        assertEq(oracle.oracleToken(), ETH_ADDRESS);
        assertEq(oracle.timestampOffset(), uint64(block.timestamp));
    }

    function test_createPool_beforeInitializePool() public {
        createPool(ETH_ADDRESS, address(token1), 0, 0, MAX_TICK_SPACING, address(oracle));
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
        createPool(ETH_ADDRESS, address(token1), 0, 0, MAX_TICK_SPACING - 1, address(oracle));

        vm.expectRevert(Oracle.FeeMustBeZero.selector);
        createPool(ETH_ADDRESS, address(token1), 0, 1, MAX_TICK_SPACING, address(oracle));
    }

    function test_createPosition() public {
        PoolKey memory poolKey = createPool(ETH_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        advanceTime(30);

        Bounds memory bounds = Bounds(-MAX_TICK_AT_MAX_TICK_SPACING, MAX_TICK_AT_MAX_TICK_SPACING);
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

    receive() external payable {}
}
