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
import {CoreLib} from "../../src/libraries/CoreLib.sol";

contract OracleTest is FullTest {
    using CoreLib for *;

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

    function test_createPosition_failsForPositionsNotWideEnough() public {
        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));
        vm.expectRevert(Oracle.BoundsMustBeMaximum.selector);
        positions.mintAndDeposit{value: 100}(
            poolKey, Bounds(-int32(MAX_TICK_SPACING), int32(MAX_TICK_SPACING)), 100, 100, 0
        );
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
        assertEq(secondsPerLiquidityCumulative, uint160(30) << 128);
        // the tick is flipped so that the price is always oracleToken/token
        assertEq(tickCumulative, 30 * -693147);

        advanceTime(45);
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity, address(this), 0, 0);
        assertEq(amount0, 99);
        assertEq(amount1, 199);

        assertEq(oracle.snapshotCount(address(token1)), 3);
        (secondsSinceOffset, secondsPerLiquidityCumulative, tickCumulative) = oracle.snapshots(address(token1), 2);
        assertEq(secondsSinceOffset, 75);
        assertEq(secondsPerLiquidityCumulative, (uint160(30) << 128) + ((uint160(45) << 128) / liquidity));
        assertEq(tickCumulative, 75 * -693147);
    }

    function movePrice(PoolKey memory poolKey, int32 targetTick) private {
        (, int32 tick) = core.poolPrice(poolKey.toPoolId());

        assert(poolKey.token0 == NATIVE_TOKEN_ADDRESS);
        assert(poolKey.token1 == address(token1));
        token1.approve(address(router), type(uint256).max);

        if (tick < targetTick) {
            router.swap{value: 1000000}(
                RouteNode(poolKey, tickToSqrtRatio(targetTick), 0), TokenAmount(address(token0), type(int128).min), 0
            );
            router.refundNativeToken();
        } else if (tick > targetTick) {
            router.swap{value: 1000000}(
                RouteNode(poolKey, tickToSqrtRatio(targetTick) + 1, 0),
                TokenAmount(address(token1), type(int128).min),
                0
            );
            router.refundNativeToken();
        }
    }

    function test_findPreviousSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, Bounds(MIN_TICK, MAX_TICK), liquidity / 2, address(this), 0, 0);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 1)
        );
        oracle.findPreviousSnapshot(address(token1), poolCreationTime - 1);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 6)
        );
        oracle.findPreviousSnapshot(address(token1), poolCreationTime - 6);

        (, uint256 i, Oracle.Snapshot memory s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime);
        assertEq(i, 0);
        assertEq(s.secondsSinceOffset, 5);
        assertEq(s.secondsPerLiquidityCumulative, 0);
        assertEq(s.tickCumulative, 0);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 9);
        assertEq(i, 0);
        assertEq(s.secondsSinceOffset, 5);
        assertEq(s.secondsPerLiquidityCumulative, 0);
        assertEq(s.tickCumulative, 0);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 10);
        assertEq(i, 1);
        assertEq(s.secondsSinceOffset, 15);
        assertEq(s.secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative, 10 * 2 * -693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 11);
        assertEq(i, 1);
        assertEq(s.secondsSinceOffset, 15);
        assertEq(s.secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative, 10 * 2 * -693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 15);
        assertEq(i, 1);
        assertEq(s.secondsSinceOffset, 15);
        assertEq(s.secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative, 10 * 2 * -693147);

        // if we pass in a future time it works fine
        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 100);
        assertEq(i, 2);
        assertEq(s.secondsSinceOffset, 21);
        assertEq(
            s.secondsPerLiquidityCumulative,
            ((uint160(10) << 128) / liquidity) + ((uint160(6) << 128) / (liquidity / 2))
        );
        assertEq(s.tickCumulative, (10 * 2 * -693147) + (-693146 / 2 * 6));
    }

    function test_extrapolateSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, Bounds(MIN_TICK, MAX_TICK), liquidity / 2, address(this), 0, 0);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        advanceTime(5);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 1)
        );
        oracle.extrapolateSnapshot(address(token1), poolCreationTime - 1);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 6)
        );
        oracle.extrapolateSnapshot(address(token1), poolCreationTime - 6);

        (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 1);
        assertEq(secondsPerLiquidityCumulative, (uint160(1) << 128) / liquidity);
        assertEq(tickCumulative, -693147 * 2);

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 9);
        assertEq(secondsPerLiquidityCumulative, (uint160(9) << 128) / liquidity);
        assertEq(tickCumulative, 9 * -693147 * 2);

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 10);
        assertEq(secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(tickCumulative, 10 * -693147 * 2);

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 11);
        assertEq(
            secondsPerLiquidityCumulative, ((uint160(10) << 128) / liquidity) + (uint160(1) << 128) / (liquidity / 2)
        );
        assertEq(tickCumulative, 10 * -693147 * 2 + (-693146 / 2));

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 21);
        assertEq(
            secondsPerLiquidityCumulative,
            // it underestimates slightly
            ((uint160(10) << 128) / liquidity) + (uint160(11) << 128) / (liquidity / 2) - 1
        );
        assertEq(tickCumulative, (10 * -693147 * 2) + (6 * -693146 / 2) + (5 * -693147));

        (uint128 liquidityAverage, int32 tickAverage) =
            oracle.getAveragesOverPeriod(NATIVE_TOKEN_ADDRESS, address(token1), poolCreationTime, poolCreationTime + 21);
        assertEq(liquidityAverage, 927);
        assertEq(tickAverage, -924195);

        (liquidityAverage, tickAverage) =
            oracle.getAveragesOverPeriod(address(token1), NATIVE_TOKEN_ADDRESS, poolCreationTime, poolCreationTime + 21);
        assertEq(liquidityAverage, 927);
        assertEq(tickAverage, 924195);
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
