// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../../src/types/poolKey.sol";
import {createStableswapPoolConfig, createFullRangePoolConfig} from "../../src/types/poolConfig.sol";
import {createPositionId} from "../../src/types/positionId.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {oracleCallPoints} from "../../src/extensions/Oracle.sol";
import {IOracle} from "../../src/interfaces/extensions/IOracle.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {Observation} from "../../src/types/observation.sol";
import {Snapshot} from "../../src/types/snapshot.sol";
import {Counts} from "../../src/types/counts.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Locker} from "../../src/types/locker.sol";

abstract contract BaseOracleTest is FullTest {
    using CoreLib for *;
    using OracleLib for *;

    IOracle internal oracle;

    uint256 positionId;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(oracleCallPoints().toUint8()) << 152);
        deployCodeTo("Oracle.sol", abi.encode(core), deployAddress);
        oracle = IOracle(deployAddress);
        positionId = positions.mint();
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(oracle));
    }

    function movePrice(PoolKey memory poolKey, int32 targetTick) internal {
        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(poolKey.toPoolId()).parse();

        if (tick < targetTick) {
            SqrtRatio targetRatio = tickToSqrtRatio(targetTick);
            TestToken(poolKey.token1).approve(address(router), type(uint256).max);
            router.swap(poolKey, false, type(int128).min, targetRatio, 0);
        } else if (tick > targetTick) {
            SqrtRatio targetRatio = toSqrtRatio(tickToSqrtRatio(targetTick).toFixed() + 1, true);
            vm.deal(address(router), amount0Delta(sqrtRatio, targetRatio, liquidity, true));
            router.swap(poolKey, true, type(int128).min, targetRatio, 0);
        }

        tick = core.poolState(poolKey.toPoolId()).tick();

        // this can happen because of rounding, we may fall just short
        assertEq(tick, targetTick, "failed to move price");
    }

    function createOraclePool(address quoteToken, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(NATIVE_TOKEN_ADDRESS, quoteToken, tick, createFullRangePoolConfig(0, address(oracle)));
    }

    function updateOraclePoolLiquidity(address token, uint128 liquidityNext) internal returns (uint128 liquidity) {
        PoolKey memory pk = PoolKey(NATIVE_TOKEN_ADDRESS, token, createFullRangePoolConfig(0, address(oracle)));
        {
            (liquidity,,,,) = positions.getPositionFeesAndLiquidity(positionId, pk, MIN_TICK, MAX_TICK);
        }

        SqrtRatio sqrtRatio = core.poolState(pk.toPoolId()).sqrtRatio();

        if (liquidity < liquidityNext) {
            (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
                sqrtRatio, int128(liquidityNext - liquidity), MIN_SQRT_RATIO, MAX_SQRT_RATIO
            );

            TestToken(token).approve(address(positions), type(uint256).max);

            vm.deal(address(positions), uint128(d0));
            positions.deposit(
                positionId, pk, MIN_TICK, MAX_TICK, uint128(d0), uint128(d1), liquidityNext - liquidity - 1
            );
            liquidity = core.poolState(pk.toPoolId()).liquidity();
            assertApproxEqAbs(liquidity, liquidityNext, 1, "liquidity after");
        } else if (liquidity > liquidityNext) {
            positions.withdraw(positionId, pk, MIN_TICK, MAX_TICK, liquidity - liquidityNext);
            liquidity = liquidityNext;
        }
    }
}

contract ManyObservationsOracleTest is BaseOracleTest {
    PoolKey poolKey;

    uint256 startTime;
    address token;

    function setUp() public override {
        BaseOracleTest.setUp();
        startTime = vm.getBlockTimestamp();

        token = address(token1);
        poolKey = createOraclePool(token, 693129);
        oracle.expandCapacity(token, 50);

        // t = startTime + 0
        updateOraclePoolLiquidity(token, 100_000);
        movePrice(poolKey, 1386256);

        advanceTime(12);

        // t = startTime + 12
        movePrice(poolKey, -693129);
        updateOraclePoolLiquidity(token, 5_000);

        advanceTime(12);

        // t = startTime + 24
        movePrice(poolKey, 693129);
        updateOraclePoolLiquidity(token, 75_000);

        // t = startTime + 36
        advanceTime(12);
        movePrice(poolKey, 1386256);
        updateOraclePoolLiquidity(token, 50_000);

        // t = startTime + 44
        advanceTime(8);
    }

    /// forge-config: default.isolate = true
    function test_gas_getSnapshots() public {
        uint256[] memory timestamps = new uint256[](6);
        timestamps[0] = startTime;
        timestamps[1] = startTime + 6;
        timestamps[2] = startTime + 18;
        timestamps[3] = startTime + 36;
        timestamps[4] = startTime + 40;
        timestamps[5] = startTime + 44;
        coolAllContracts();
        oracle.getExtrapolatedSnapshotsForSortedTimestamps(token, timestamps);
        vm.snapshotGasLastCall("getExtrapolatedSnapshotsForSortedTimestamps(6 timestamps)");
    }

    function test_values() public view {
        uint256[] memory timestamps = new uint256[](6);
        timestamps[0] = startTime;
        timestamps[1] = startTime + 6;
        timestamps[2] = startTime + 18;
        timestamps[3] = startTime + 36;
        timestamps[4] = startTime + 40;
        timestamps[5] = startTime + 44;
        Observation[] memory observations = oracle.getExtrapolatedSnapshotsForSortedTimestamps(token, timestamps);
        // startTime
        assertEq(observations[0].secondsPerLiquidityCumulative(), 0);
        assertEq(observations[0].tickCumulative(), 0);

        // startTime + 6
        assertEq(observations[1].secondsPerLiquidityCumulative(), (uint160(6) << 128) / 100_000);
        assertEq(observations[1].tickCumulative(), int64(6) * 1386256);

        // startTime + 18
        assertEq(
            observations[2].secondsPerLiquidityCumulative(),
            ((uint160(12) << 128) / 100_000) + ((uint160(6) << 128) / 5_000)
        );
        assertEq(observations[2].tickCumulative(), (int64(12) * 1386256) + (-693129 * 6));

        // startTime + 36
        assertEq(
            observations[3].secondsPerLiquidityCumulative(),
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
        );
        assertEq(observations[3].tickCumulative(), (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12));

        // startTime + 40
        assertEq(
            observations[4].secondsPerLiquidityCumulative(),
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
                + ((uint160(4) << 128) / 50_000)
        );
        assertEq(
            observations[4].tickCumulative(), (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12) + (1386256 * 4)
        );

        // startTime + 44
        assertEq(
            observations[5].secondsPerLiquidityCumulative(),
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
                + ((uint160(8) << 128) / 50_000)
        );
        assertEq(
            observations[5].tickCumulative(), (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12) + (1386256 * 8)
        );
    }
}

contract OracleTest is BaseOracleTest {
    using CoreLib for *;
    using OracleLib for *;

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(oracle)));
    }

    struct DataPoint {
        uint16 advanceTimeBy;
        uint8 minCapacity;
        uint56 liquidity;
        int32 tick;
    }

    function test_canReadPoints_random_data(
        uint256 startTime,
        int32 startingTick,
        DataPoint[] memory points,
        uint32 checkOffset
    ) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        startingTick = int32(bound(startingTick, MIN_TICK, MAX_TICK));

        address token = address(token0);

        PoolKey memory poolKey = createOraclePool(token, startingTick);

        uint32 totalTimePassed;

        uint32 capacity = 1;

        for (uint256 i = 0; i < points.length; i++) {
            points[i].tick = int32(bound(points[i].tick, MIN_TICK, MAX_TICK));
            advanceTime(points[i].advanceTimeBy);
            totalTimePassed += points[i].advanceTimeBy;
            capacity = oracle.expandCapacity(token, points[i].minCapacity);
            points[i].liquidity = uint56(updateOraclePoolLiquidity(token, points[i].liquidity));
            movePrice(poolKey, points[i].tick);
        }

        checkOffset = uint32(bound(checkOffset, 0, totalTimePassed * 2));

        uint256 timeToCheck = startTime + checkOffset;

        if (timeToCheck > vm.getBlockTimestamp()) {
            vm.expectRevert(IOracle.FutureTime.selector);
            oracle.extrapolateSnapshot(token, startTime + checkOffset);
        } else if (timeToCheck < oracle.getEarliestSnapshotTimestamp(token)) {
            vm.expectRevert(abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, token, timeToCheck));
            oracle.extrapolateSnapshot(token, timeToCheck);
        } else {
            (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
                oracle.extrapolateSnapshot(token, timeToCheck);

            // todo: verify the computation using the full list of points
            uint256 i = 0;
            uint256 time = startTime;

            int32 tick = startingTick;
            uint128 liquidity = 0;

            int64 tickCumulativeExpected;
            uint160 secondsPerLiquidityCumulativeExpected;
            uint256 secondsPerLiquidityTolerance = 1;

            while (i < points.length) {
                // time is the end time of the period
                if (time >= timeToCheck) {
                    break;
                }

                DataPoint memory point = points[i++];

                uint256 timePassed = FixedPointMathLib.min(time + point.advanceTimeBy, timeToCheck) - time;

                tickCumulativeExpected += int64(uint64(timePassed)) * tick;
                secondsPerLiquidityCumulativeExpected += (uint160(timePassed) << 128)
                    / uint160(FixedPointMathLib.max(1, liquidity));

                // an observation was not written for this, so the seconds per liquidity accumulator can be off from the calculated by the rounding error
                // since each time we do an addition of time passed / liquidity, we divide and round down
                if (liquidity == point.liquidity && tick == point.tick) {
                    secondsPerLiquidityTolerance += 1;
                }

                tick = point.tick;
                liquidity = point.liquidity;

                time += point.advanceTimeBy;
            }

            assertEq(tickCumulative, tickCumulativeExpected, "tickCumulative");
            assertApproxEqAbs(
                secondsPerLiquidityCumulative,
                secondsPerLiquidityCumulativeExpected,
                secondsPerLiquidityTolerance,
                "secondsPerLiquidityCumulative"
            );
        }
    }

    function test_createPool_beforeInitializePool(uint256 time) public {
        vm.warp(time);
        createOraclePool(address(token1), 1000);

        Counts c = oracle.counts(address(token1));

        assertEq(c.index(), 0);
        assertEq(c.count(), 1);
        assertEq(c.capacity(), 1);
        assertEq(c.lastTimestamp(), uint32(time));

        Snapshot snapshot = oracle.snapshots(address(token1), 0);
        assertEq(snapshot.timestamp(), uint32(time));
        assertEq(snapshot.secondsPerLiquidityCumulative(), 0);
        assertEq(snapshot.tickCumulative(), 0);
    }

    function test_snapshotEvent_emitted_at_create(uint256 time) public {
        vm.warp(time);

        vm.recordLogs();
        createOraclePool(address(token1), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(oracle));
        assertEq(logs[0].topics.length, 0);
        assertEq(logs[0].data.length, 52);
        assertEq(address(bytes20(LibBytes.load(logs[0].data, 0))), address(token1));
        assertEq(int64(uint64(bytes8(LibBytes.load(logs[0].data, 20)))), 0);
        assertEq(uint160(bytes20(LibBytes.load(logs[0].data, 28))), 0);
        assertEq(uint32(bytes4(LibBytes.load(logs[0].data, 48))), uint32(time));

        assertEq(logs[1].emitter, address(core));
    }

    function test_snapshotEvent_emitted_at_swap(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        PoolKey memory poolKey = createOraclePool(address(token1), 1000);
        updateOraclePoolLiquidity(address(token1), 5000);
        advanceTime(5);
        vm.recordLogs();
        movePrice(poolKey, -3000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        Vm.Log memory log = logs[0];
        assertEq(log.emitter, address(oracle));
        assertEq(log.topics.length, 0);
        assertEq(log.data.length, 52);
        assertEq(address(bytes20(LibBytes.load(log.data, 0))), address(token1));
        assertEq(uint32(bytes4(LibBytes.load(log.data, 48))), uint32(startTime + 5));
        assertEq(uint160(bytes20(LibBytes.load(log.data, 28))), (uint256(5) << 128) / 5000);
        assertEq(int64(uint64(bytes8(LibBytes.load(log.data, 20)))), 5000);

        updateOraclePoolLiquidity(address(token1), 100_000);

        advanceTime(10);

        vm.recordLogs();
        updateOraclePoolLiquidity(address(token1), 1000);
        logs = vm.getRecordedLogs();

        assertEq(logs.length, 4);
        log = logs[1];
        assertEq(log.emitter, address(oracle));
        assertEq(log.topics.length, 0);
        assertEq(log.data.length, 52);
        assertEq(address(bytes20(LibBytes.load(log.data, 0))), address(token1));
        assertEq(uint32(bytes4(LibBytes.load(log.data, 48))), uint32(startTime + 15));
        assertEq(
            uint160(bytes20(LibBytes.load(log.data, 28))),
            ((uint256(5) << 128) / 5000) + ((uint256(10) << 128) / 100_000)
        );
        assertEq(int64(uint64(bytes8(LibBytes.load(log.data, 20)))), -25000);
    }

    function test_createPool_beforeInitializePool_first_expandCapacity(uint256 time) public {
        vm.warp(time);
        oracle.expandCapacity(address(token1), 10);
        createOraclePool(address(token1), 0);
        Counts c = oracle.counts(address(token1));
        assertEq(c.index(), 0);
        assertEq(c.count(), 1);
        assertEq(c.capacity(), 10);
        assertEq(c.lastTimestamp(), uint32(block.timestamp));
    }

    function test_expandCapacity_returns_old_if_not_expanded() public {
        assertEq(oracle.expandCapacity(address(token1), 10), 10);
        assertEq(oracle.expandCapacity(address(token1), 5), 10);
    }

    function test_createPool_beforeInitializePool_then_expandCapacity(uint256 time) public {
        vm.warp(time);
        createOraclePool(address(token1), 0);
        oracle.expandCapacity(address(token1), 10);
        Counts c = oracle.counts(address(token1));
        assertEq(c.index(), 0);
        assertEq(c.count(), 1);
        assertEq(c.capacity(), 10);
        assertEq(c.lastTimestamp(), uint32(time));
    }

    function test_expandCapacity_doesNotOverwrite(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        PoolKey memory pk = createOraclePool(address(token1), 2000);
        advanceTime(12);
        movePrice(pk, -500);
        advanceTime(6);
        movePrice(pk, 1000);
        oracle.expandCapacity(address(token1), 2);

        Counts c = oracle.counts(address(token1));
        assertEq(c.index(), 0);
        assertEq(c.count(), 1);
        assertEq(c.capacity(), 2);
        assertEq(c.lastTimestamp(), uint32(startTime + 18));
        Snapshot snapshot = oracle.snapshots(address(token1), 0);
        unchecked {
            assertEq(snapshot.timestamp(), uint32(startTime) + 18);
        }
        assertEq(snapshot.secondsPerLiquidityCumulative(), uint256(18) << 128);
        assertEq(snapshot.tickCumulative(), (2000 * 12) + (-500 * 6));

        // empty snapshot initialized
        snapshot = oracle.snapshots(address(token1), 1);
        assertEq(snapshot.timestamp(), 1); // this is an empty snapshot
        assertEq(snapshot.secondsPerLiquidityCumulative(), 0);
        assertEq(snapshot.tickCumulative(), 0);
    }

    function test_snapshots_circularWriteAtCapacity(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        PoolKey memory pk = createOraclePool(address(token1), 2000);
        // writes 0
        advanceTime(2);
        movePrice(pk, -500);
        oracle.expandCapacity(address(token1), 3);
        // writes 1
        advanceTime(3);
        movePrice(pk, 700);
        // writes 2
        advanceTime(6);
        movePrice(pk, -5000);
        // writes 0
        advanceTime(4);
        movePrice(pk, 0);

        Counts c = oracle.counts(address(token1));
        assertEq(c.index(), 0, "index");
        assertEq(c.count(), 3, "count");
        assertEq(c.capacity(), 3, "capacity");
        assertEq(c.lastTimestamp(), uint32(startTime + 2 + 3 + 6 + 4));

        Snapshot snapshot = oracle.snapshots(address(token1), 0);
        unchecked {
            assertEq(snapshot.timestamp(), uint32(startTime) + 4 + 6 + 3 + 2);
        }
        assertEq(snapshot.secondsPerLiquidityCumulative(), uint256(4 + 6 + 3 + 2) << 128);
        assertEq(snapshot.tickCumulative(), (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));
    }

    function test_snapshots_extrapolateWorksAfterRotate(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        PoolKey memory pk = createOraclePool(address(token1), 2000);
        // writes 0
        advanceTime(2);
        movePrice(pk, -500);
        oracle.expandCapacity(address(token1), 3);
        // writes 1
        advanceTime(3);
        movePrice(pk, 700);
        // writes 2
        advanceTime(6);
        movePrice(pk, -5000);
        // writes 0
        advanceTime(4);
        movePrice(pk, 0);

        // end time is start+18
        advanceTime(3);

        vm.expectRevert(abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime));
        oracle.extrapolateSnapshot(address(token1), startTime);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime + 2)
        );
        oracle.extrapolateSnapshot(address(token1), startTime + 2);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime + 4)
        );
        oracle.extrapolateSnapshot(address(token1), startTime + 4);

        (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), startTime + 5);
        assertEq(secondsPerLiquidityCumulative, uint256(5) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), startTime + 6);
        assertEq(secondsPerLiquidityCumulative, uint256(6) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), startTime + 12);
        assertEq(secondsPerLiquidityCumulative, uint256(12) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), startTime + 16);
        assertEq(secondsPerLiquidityCumulative, uint256(16) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), startTime + 18);
        assertEq(secondsPerLiquidityCumulative, uint256(18) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));

        vm.expectRevert(IOracle.FutureTime.selector);
        oracle.extrapolateSnapshot(address(token1), startTime + 19);
    }

    function test_createPool_beforeInitializePool_reverts() public {
        vm.expectRevert(IOracle.PairsWithNativeTokenOnly.selector);
        createPool(address(token0), address(token1), 0, createFullRangePoolConfig(0, address(oracle)));

        vm.expectRevert(IOracle.FullRangePoolOnly.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, createStableswapPoolConfig(0, 15, 0, address(oracle)));

        vm.expectRevert(IOracle.FeeMustBeZero.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, createStableswapPoolConfig(1, 0, 0, address(oracle)));
    }

    function test_createPosition(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        advanceTime(30);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 100, 200);
        Counts c = oracle.counts(address(token1));

        assertEq(c.count(), 1);
        assertEq(c.index(), 0);
        assertEq(c.capacity(), 1);
        assertEq(c.lastTimestamp(), uint32(startTime + 30));
        Snapshot snapshot = oracle.snapshots(address(token1), 0);
        unchecked {
            assertEq(snapshot.timestamp(), uint32(startTime) + 30);
        }
        assertEq(snapshot.secondsPerLiquidityCumulative(), uint160(30) << 128);
        // the tick is flipped so that the price is always oracleToken/token
        assertEq(snapshot.tickCumulative(), 30 * 693147);

        advanceTime(45);
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity);
        assertEq(amount0, 99);
        assertEq(amount1, 199);

        Counts c2 = oracle.counts(address(token1));
        assertEq(c2.count(), 1);
        assertEq(c2.index(), 0);
        assertEq(c2.capacity(), 1);
        assertEq(c2.lastTimestamp(), uint32(startTime + 75));

        snapshot = oracle.snapshots(address(token1), 0);
        unchecked {
            assertEq(snapshot.timestamp(), uint32(startTime) + 75);
        }
        assertEq(snapshot.secondsPerLiquidityCumulative(), (uint160(30) << 128) + ((uint160(45) << 128) / liquidity));
        assertEq(snapshot.tickCumulative(), 75 * 693147);
    }

    function test_findPreviousSnapshot(uint256 startTime) public {
        startTime = bound(startTime, 5, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        oracle.expandCapacity(address(token1), 10);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity / 2);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime - 1)
        );
        oracle.findPreviousSnapshot(address(token1), startTime - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime - 4)
        );
        oracle.findPreviousSnapshot(address(token1), startTime - 4);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), startTime - 5)
        );
        oracle.findPreviousSnapshot(address(token1), startTime - 5);

        (, uint256 i, Snapshot s) = oracle.findPreviousSnapshot(address(token1), startTime);
        assertEq(i, 0);
        assertEq(s.timestamp(), uint32(startTime));
        assertEq(s.secondsPerLiquidityCumulative(), 0);
        assertEq(s.tickCumulative(), 0);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), startTime + 9);
        assertEq(i, 0);
        unchecked {
            assertEq(s.timestamp(), uint32(startTime));
        }
        assertEq(s.secondsPerLiquidityCumulative(), 0);
        assertEq(s.tickCumulative(), 0);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), startTime + 10);
        assertEq(i, 1);
        unchecked {
            assertEq(s.timestamp(), uint32(startTime) + 10);
        }
        assertEq(s.secondsPerLiquidityCumulative(), (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative(), 10 * 2 * 693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), startTime + 11);
        assertEq(i, 1);
        unchecked {
            assertEq(s.timestamp(), uint32(startTime) + 10);
        }
        assertEq(s.secondsPerLiquidityCumulative(), (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative(), 10 * 2 * 693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), startTime + 15);
        assertEq(i, 1);
        unchecked {
            assertEq(s.timestamp(), uint32(startTime) + 10);
        }
        assertEq(s.secondsPerLiquidityCumulative(), (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative(), 10 * 2 * 693147);

        // if we pass in a future time it reverts
        vm.expectRevert(abi.encodeWithSelector(IOracle.FutureTime.selector));
        oracle.findPreviousSnapshot(address(token1), startTime + 100);
    }

    function test_extrapolateSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        oracle.expandCapacity(address(token1), 10);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity / 2);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        advanceTime(5);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 1)
        );
        oracle.extrapolateSnapshot(address(token1), poolCreationTime - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IOracle.NoPreviousSnapshotExists.selector, address(token1), poolCreationTime - 6)
        );
        oracle.extrapolateSnapshot(address(token1), poolCreationTime - 6);

        (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 1);
        assertEq(secondsPerLiquidityCumulative, (uint160(1) << 128) / liquidity);
        assertEq(tickCumulative, 693147 * 2, "t=1");

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 9);
        assertEq(secondsPerLiquidityCumulative, (uint160(9) << 128) / liquidity);
        assertEq(tickCumulative, 9 * 693147 * 2, "t=9");

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 10);
        assertEq(secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(tickCumulative, 10 * 693147 * 2, "t=10");

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 11);
        assertEq(
            secondsPerLiquidityCumulative, ((uint160(10) << 128) / liquidity) + (uint160(1) << 128) / (liquidity / 2)
        );
        assertEq(tickCumulative, 10 * 693147 * 2 + (693146 / 2), "t=11");

        (secondsPerLiquidityCumulative, tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), poolCreationTime + 21);
        assertEq(
            secondsPerLiquidityCumulative,
            // it underestimates slightly
            ((uint160(10) << 128) / liquidity) + (uint160(11) << 128) / (liquidity / 2) - 1
        );
        assertEq(tickCumulative, (10 * 693147 * 2) + (6 * 693146 / 2) + (5 * 693147), "t=21");
    }

    /// forge-config: default.isolate = true
    function test_getExtrapolatedSnapshots_gas() public {
        oracle.expandCapacity(address(token1), 5);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 2000);

        movePrice(poolKey, 693147 * 2);
        advanceTime(10);
        positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity / 2);
        movePrice(poolKey, 693146 / 2);
        advanceTime(6);
        movePrice(poolKey, 693147);
        advanceTime(5);

        uint256[] memory timestamps = new uint256[](2);
        timestamps[0] = vm.getBlockTimestamp() - 1;
        timestamps[1] = vm.getBlockTimestamp();

        coolAllContracts();
        oracle.getExtrapolatedSnapshotsForSortedTimestamps(address(token1), timestamps);
        vm.snapshotGasLastCall("oracle#getExtrapolatedSnapshots");
    }

    /// forge-config: default.isolate = true
    function test_getExtrapolatedSnapshots() public {
        uint64 poolCreationTime = uint64(advanceTime(5));

        oracle.expandCapacity(address(token1), 5);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity / 2);

        uint128 liquidity2 = liquidity - (liquidity / 2);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        advanceTime(5);

        uint256[] memory timestamps = new uint256[](8);
        timestamps[0] = poolCreationTime;
        timestamps[1] = poolCreationTime + 3;
        timestamps[2] = poolCreationTime + 6;
        timestamps[3] = poolCreationTime + 9;
        timestamps[4] = poolCreationTime + 12;
        timestamps[5] = poolCreationTime + 15;
        timestamps[6] = poolCreationTime + 18;
        timestamps[7] = poolCreationTime + 21;
        coolAllContracts();
        Observation[] memory observations =
            oracle.getExtrapolatedSnapshotsForSortedTimestamps(address(token1), timestamps);

        vm.snapshotGasLastCall("oracle.getExtrapolatedSnapshots(address(token1), 21, 3, 8)");

        assertEq(observations.length, timestamps.length);

        // liquidity
        assertEq(observations[0].secondsPerLiquidityCumulative(), 0);
        assertEq(observations[1].secondsPerLiquidityCumulative(), (uint256(3) << 128) / liquidity);
        assertEq(observations[2].secondsPerLiquidityCumulative(), (uint256(6) << 128) / liquidity);
        assertEq(observations[3].secondsPerLiquidityCumulative(), (uint256(9) << 128) / liquidity);
        assertEq(
            observations[4].secondsPerLiquidityCumulative(),
            ((uint256(10) << 128) / liquidity) + ((uint256(2) << 128) / liquidity2)
        );
        assertEq(
            observations[5].secondsPerLiquidityCumulative(),
            // rounded down
            ((uint256(10) << 128) / liquidity) + ((uint256(5) << 128) / liquidity2) - 1
        );
        assertEq(
            observations[6].secondsPerLiquidityCumulative(),
            // rounded down
            ((uint256(10) << 128) / liquidity) + ((uint256(8) << 128) / liquidity2) - 1
        );
        assertEq(
            observations[7].secondsPerLiquidityCumulative(),
            // rounded down
            ((uint256(10) << 128) / liquidity) + ((uint256(11) << 128) / liquidity2) - 1
        );

        // ticks always expressed in oracle token / token
        assertEq(observations[0].tickCumulative(), 0);
        assertEq(observations[1].tickCumulative(), (693147 * 2) * 3);
        assertEq(observations[2].tickCumulative(), (693147 * 2) * 6);
        assertEq(observations[3].tickCumulative(), (693147 * 2) * 9);
        assertEq(observations[4].tickCumulative(), (693147 * 2) * 10 + ((346573) * 2));
        assertEq(observations[5].tickCumulative(), (693147 * 2) * 10 + ((346573) * 5));
        assertEq(observations[6].tickCumulative(), (693147 * 2) * 10 + ((346573) * 6) + (693147 * 2));
        assertEq(observations[7].tickCumulative(), (693147 * 2) * 10 + ((346573) * 6) + (693147 * 5));
    }

    function test_cannotCallExtensionMethodsDirectly() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeInitializePool(address(0), poolKey, 15);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeUpdatePosition(
            Locker.wrap(bytes32(0)),
            poolKey,
            createPositionId({_salt: bytes24(0), _tickLower: -100, _tickUpper: 100}),
            0
        );

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeSwap(Locker.wrap(bytes32(0)), poolKey, createSwapParameters(SqrtRatio.wrap(0), 0, false, 0));
    }

    /// forge-config: default.isolate = true
    function test_gas_swap_on_oracle_pool() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);
        updateOraclePoolLiquidity(address(token1), 1e18);

        TestToken(poolKey.token1).approve(address(router), type(uint256).max);

        advanceTime(1);
        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);

        advanceTime(1);
        coolAllContracts();
        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token1 in with write");

        advanceTime(1);
        coolAllContracts();
        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token0 in with write");

        coolAllContracts();
        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token1 in no write");

        coolAllContracts();
        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token0 in no write");
    }
}
