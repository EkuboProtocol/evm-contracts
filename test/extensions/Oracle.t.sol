// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {NATIVE_TOKEN_ADDRESS, UpdatePositionParameters, SwapParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../../src/types/keys.sol";
import {
    MIN_TICK,
    MAX_TICK,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    MAX_TICK_SPACING,
    tickToSqrtRatio
} from "../../src/math/ticks.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle} from "../../src/extensions/Oracle.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";

abstract contract BaseOracleTest is FullTest {
    using CoreLib for *;

    Oracle internal oracle;
    TestToken internal oracleToken;

    uint256 positionId;

    function setUp() public virtual override {
        FullTest.setUp();
        oracleToken = new TestToken(address(this));
        if (address(token0) < address(oracleToken)) {
            (oracleToken, token0) = (token0, oracleToken);
        }
        if (address(token1) < address(oracleToken)) {
            (oracleToken, token1) = (token1, oracleToken);
        }
        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }
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
        deployCodeTo("Oracle.sol", abi.encode(core, oracleToken), deployAddress);
        oracle = Oracle(deployAddress);
        positionId = positions.mint();
    }

    function advanceTime(uint32 by) internal {
        vm.warp(vm.getBlockTimestamp() + by);
    }

    function movePrice(PoolKey memory poolKey, int32 targetTick) internal {
        (uint192 sqrtRatio, int32 tick) = core.poolPrice(poolKey.toPoolId());
        uint128 liquidity = core.poolLiquidity(poolKey.toPoolId());

        bool isToken0ETH = poolKey.token0 == NATIVE_TOKEN_ADDRESS;
        if (!isToken0ETH) {
            TestToken(poolKey.token0).approve(address(router), type(uint256).max);
        }
        TestToken(poolKey.token1).approve(address(router), type(uint256).max);

        if (tick < targetTick) {
            uint256 targetRatio = tickToSqrtRatio(targetTick);
            uint128 amount = amount1Delta(sqrtRatio, targetRatio, liquidity, true);
            router.swap(RouteNode(poolKey, targetRatio, 0), TokenAmount(poolKey.token1, int128(amount)));
        } else if (tick > targetTick) {
            uint256 targetRatio = tickToSqrtRatio(targetTick) + 1;
            uint128 amount = amount0Delta(sqrtRatio, targetRatio, liquidity, true);
            router.swap{value: isToken0ETH ? amount : 0}(
                RouteNode(poolKey, targetRatio, 0), TokenAmount(poolKey.token0, int128(amount))
            );
        }
    }

    function createOraclePool(address baseToken, int32 tick) internal returns (PoolKey memory poolKey) {
        address t0;
        address t1;
        (t0, t1, tick) = baseToken < address(oracleToken)
            ? (baseToken, address(oracleToken), tick)
            : (address(oracleToken), baseToken, -tick);
        poolKey = createPool(t0, t1, tick, 0, MAX_TICK_SPACING, address(oracle));
    }

    function updateOraclePoolLiquidity(address token, uint128 liquidityNext) internal {
        (address t0, address t1) =
            token < address(oracleToken) ? (token, address(oracleToken)) : (address(oracleToken), token);
        PoolKey memory pk = PoolKey(t0, t1, 0, MAX_TICK_SPACING, address(oracle));
        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);
        // todo: finish this for the price fetcher tests
        (uint128 liquidity,,,,) = positions.getPositionFeesAndLiquidity(positionId, pk, bounds);

        (uint256 sqrtRatio,) = positions.getPoolPrice(pk);
        if (liquidity < liquidityNext) {
            (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
                sqrtRatio, int128(liquidityNext - liquidity), MIN_SQRT_RATIO, MAX_SQRT_RATIO
            );

            bool isETH = t0 == NATIVE_TOKEN_ADDRESS;
            if (!isETH) {
                TestToken(t0).approve(address(positions), uint128(d0));
            }
            TestToken(t1).approve(address(positions), uint128(d1));

            positions.deposit(positionId, pk, bounds, uint128(d0), uint128(d1), liquidityNext - liquidity);
            assertEq(positions.getPoolLiquidity(pk), liquidityNext);
        } else if (liquidity > liquidityNext) {
            positions.withdraw(positionId, pk, bounds, liquidity - liquidityNext);
        }
    }
}

contract OracleTest is BaseOracleTest {
    using CoreLib for *;

    function test_getImmutables() public view {
        assertEq(oracle.oracleToken(), address(oracleToken));
        assertEq(oracle.timestampOffset(), uint64(block.timestamp));
    }

    function test_createPool_beforeInitializePool() public {
        createPool(address(oracleToken), address(token1), 0, 0, MAX_TICK_SPACING, address(oracle));
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
        createPool(address(oracleToken), address(token1), 0, 0, MAX_TICK_SPACING - 1, address(oracle));

        vm.expectRevert(Oracle.FeeMustBeZero.selector);
        createPool(address(oracleToken), address(token1), 0, 1, MAX_TICK_SPACING, address(oracle));
    }

    function test_createPosition_failsForPositionsNotWideEnough() public {
        PoolKey memory poolKey =
            createPool(address(oracleToken), address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));
        vm.expectRevert(Oracle.BoundsMustBeMaximum.selector);
        positions.mintAndDeposit{value: 100}(
            poolKey, Bounds(-int32(MAX_TICK_SPACING), int32(MAX_TICK_SPACING)), 100, 100, 0
        );
    }

    function test_createPosition() public {
        PoolKey memory poolKey =
            createPool(address(oracleToken), address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

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
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity);
        assertEq(amount0, 99);
        assertEq(amount1, 199);

        assertEq(oracle.snapshotCount(address(token1)), 3);
        (secondsSinceOffset, secondsPerLiquidityCumulative, tickCumulative) = oracle.snapshots(address(token1), 2);
        assertEq(secondsSinceOffset, 75);
        assertEq(secondsPerLiquidityCumulative, (uint160(30) << 128) + ((uint160(45) << 128) / liquidity));
        assertEq(tickCumulative, 75 * -693147);
    }

    function test_findPreviousSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        PoolKey memory poolKey =
            createPool(address(oracleToken), address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, Bounds(MIN_TICK, MAX_TICK), liquidity / 2);

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

    function test_getAverageMultihop() public {
        uint64 startTime = uint64(block.timestamp);
        // 2 ETH / token0
        PoolKey memory poolKey0 =
            createPool(address(oracleToken), address(token0), -693147, 0, MAX_TICK_SPACING, address(oracle));
        // 0.25 ETH / token1
        PoolKey memory poolKey1 =
            createPool(address(oracleToken), address(token1), 693147 * 2, 0, MAX_TICK_SPACING, address(oracle));

        createPosition(poolKey0, Bounds(MIN_TICK, MAX_TICK), 2000, 1000); // ~1414
        createPosition(poolKey1, Bounds(MIN_TICK, MAX_TICK), 3000, 12000); // ~6000

        advanceTime(12);

        // to 1 ETH / token0, meaning more token0 is sold into the pool
        movePrice(poolKey0, 0);
        // to 0.004 ETH / token1, meaning much more token1 is sold into the pool
        movePrice(poolKey1, 693147 * 8);

        advanceTime(12);

        // first 12 seconds the token1/token0 price is 1 token1 / 8 token0
        (uint128 liquidity, int32 tick) =
            oracle.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 12);
        // combined should be about sqrt(1000*12000) = ~3464
        assertEq(liquidity, 3461);
        assertEq(tick, -2079441); // ~= 1/8

        // first half of first period is the same
        (liquidity, tick) = oracle.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 6);
        assertEq(liquidity, 3461);
        assertEq(tick, -2079441);

        // liquidity goes up considerably because token0 and token1 are sold into the pools
        (liquidity, tick) =
            oracle.getAveragesOverPeriod(address(token0), address(token1), startTime + 6, startTime + 18);
        assertEq(liquidity, 6352);
        assertEq(tick, -3812308); // ~= 0.022097162025342

        // second period
        (liquidity, tick) =
            oracle.getAveragesOverPeriod(address(token0), address(token1), startTime + 12, startTime + 24);
        assertEq(liquidity, 11645);
        assertEq(tick, -5545176); // ~= 1.000001^(-5545176) ~= 0.003906266472948

        // second half of second period
        (liquidity, tick) =
            oracle.getAveragesOverPeriod(address(token0), address(token1), startTime + 18, startTime + 24);
        assertEq(liquidity, 11645);
        assertEq(tick, -5545176);

        oracle.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 24);
        vm.snapshotGasLastCall("getAveragesOverPeriod");
    }

    function test_extrapolateSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        PoolKey memory poolKey =
            createPool(address(oracleToken), address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, Bounds(MIN_TICK, MAX_TICK), liquidity / 2);

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
            oracle.getAveragesOverPeriod(address(oracleToken), address(token1), poolCreationTime, poolCreationTime + 21);
        assertEq(liquidityAverage, 927);
        assertEq(tickAverage, -924195);

        (liquidityAverage, tickAverage) =
            oracle.getAveragesOverPeriod(address(token1), address(oracleToken), poolCreationTime, poolCreationTime + 21);
        assertEq(liquidityAverage, 927);
        assertEq(tickAverage, 924195);
    }

    function test_cannotCallExtensionMethodsDirectly() public {
        PoolKey memory poolKey =
            createPool(address(oracleToken), address(token1), 693147, 0, MAX_TICK_SPACING, address(oracle));

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeInitializePool(address(0), poolKey, 0);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeUpdatePosition(address(0), poolKey, UpdatePositionParameters(bytes32(0x0), Bounds(-100, 100), 0));

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeSwap(address(0), poolKey, SwapParameters(0, false, 0, 0));
    }

    receive() external payable {}
}
