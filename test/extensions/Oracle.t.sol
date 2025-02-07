// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {UpdatePositionParameters, SwapParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionKey, Bounds} from "../../src/types/positionKey.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {
    MIN_TICK,
    MAX_TICK,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    MAX_TICK_SPACING,
    FULL_RANGE_ONLY_TICK_SPACING,
    NATIVE_TOKEN_ADDRESS
} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle} from "../../src/extensions/Oracle.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FullRangeOnlyPool} from "../../src/types/positionKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";

abstract contract BaseOracleTest is FullTest {
    using CoreLib for *;

    Oracle internal oracle;

    uint256 positionId;

    function setUp() public virtual override {
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
        deployCodeTo("Oracle.sol", abi.encode(core), deployAddress);
        oracle = Oracle(deployAddress);
        positionId = positions.mint();
    }

    function advanceTime(uint32 by) internal returns (uint64 next) {
        next = uint64(vm.getBlockTimestamp() + by);
        vm.warp(next);
    }

    function movePrice(PoolKey memory poolKey, int32 targetTick) internal {
        (uint192 sqrtRatio, int32 tick) = core.poolPrice(poolKey.toPoolId());
        uint128 liquidity = core.poolLiquidity(poolKey.toPoolId());

        if (tick < targetTick) {
            uint256 targetRatio = tickToSqrtRatio(targetTick);
            TestToken(poolKey.token1).approve(address(router), type(uint256).max);
            router.swap(poolKey, false, type(int128).min, targetRatio, 0);
        } else if (tick > targetTick) {
            uint256 targetRatio = tickToSqrtRatio(targetTick) + 1;
            vm.deal(address(router), amount0Delta(sqrtRatio, targetRatio, liquidity, true));
            router.swap(poolKey, true, type(int128).min, targetRatio, 0);
        }

        (, tick) = core.poolPrice(poolKey.toPoolId());

        // this can happen because of rounding, we may fall just short
        assertEq(tick, targetTick, "failed to move price");
    }

    function createOraclePool(address quoteToken, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(NATIVE_TOKEN_ADDRESS, quoteToken, tick, 0, FULL_RANGE_ONLY_TICK_SPACING, address(oracle));
    }

    function updateOraclePoolLiquidity(address token, uint128 liquidityNext) internal {
        PoolKey memory pk = PoolKey(NATIVE_TOKEN_ADDRESS, token, 0, FULL_RANGE_ONLY_TICK_SPACING, address(oracle));
        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);
        // todo: finish this for the price fetcher tests
        (uint128 liquidity,,,,) = positions.getPositionFeesAndLiquidity(positionId, pk, bounds);

        (uint256 sqrtRatio,) = core.poolPrice(pk.toPoolId());
        if (liquidity < liquidityNext) {
            (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
                sqrtRatio, int128(liquidityNext - liquidity), MIN_SQRT_RATIO, MAX_SQRT_RATIO
            );

            TestToken(token).approve(address(positions), type(uint256).max);

            vm.deal(address(positions), uint128(d0));
            positions.deposit(positionId, pk, bounds, uint128(d0), uint128(d1), liquidityNext - liquidity);
            assertEq(core.poolLiquidity(pk.toPoolId()), liquidityNext);
        } else if (liquidity > liquidityNext) {
            positions.withdraw(positionId, pk, bounds, liquidity - liquidityNext);
        }
    }
}

contract ManyObservationsOracleTest is BaseOracleTest {
    PoolKey poolKey;

    uint64 startTime;
    address token;

    function setUp() public override {
        BaseOracleTest.setUp();
        startTime = uint64(vm.getBlockTimestamp());
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

    function test_gas_getSnapshots() public {
        uint64[] memory timestamps = new uint64[](6);
        timestamps[0] = startTime;
        timestamps[1] = startTime + 6;
        timestamps[2] = startTime + 18;
        timestamps[3] = startTime + 36;
        timestamps[4] = startTime + 40;
        timestamps[5] = startTime + 44;
        oracle.getExtrapolatedSnapshotsForSortedTimestamps(token, timestamps);
        vm.snapshotGasLastCall("getExtrapolatedSnapshotsForSortedTimestamps(6 timestamps)");
    }

    function test_values() public view {
        uint64[] memory timestamps = new uint64[](6);
        timestamps[0] = startTime;
        timestamps[1] = startTime + 6;
        timestamps[2] = startTime + 18;
        timestamps[3] = startTime + 36;
        timestamps[4] = startTime + 40;
        timestamps[5] = startTime + 44;
        Oracle.Observation[] memory observations = oracle.getExtrapolatedSnapshotsForSortedTimestamps(token, timestamps);
        // startTime
        assertEq(observations[0].secondsPerLiquidityCumulative, 0);
        assertEq(observations[0].tickCumulative, 0);

        // startTime + 6
        assertEq(observations[1].secondsPerLiquidityCumulative, (uint160(6) << 128) / 100_000);
        assertEq(observations[1].tickCumulative, int64(6) * 1386256);

        // startTime + 18
        assertEq(
            observations[2].secondsPerLiquidityCumulative,
            ((uint160(12) << 128) / 100_000) + ((uint160(6) << 128) / 5_000)
        );
        assertEq(observations[2].tickCumulative, (int64(12) * 1386256) + (-693129 * 6));

        // startTime + 36
        assertEq(
            observations[3].secondsPerLiquidityCumulative,
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
        );
        assertEq(observations[3].tickCumulative, (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12));

        // startTime + 40
        assertEq(
            observations[4].secondsPerLiquidityCumulative,
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
                + ((uint160(4) << 128) / 50_000)
        );
        assertEq(observations[4].tickCumulative, (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12) + (1386256 * 4));

        // startTime + 44
        assertEq(
            observations[5].secondsPerLiquidityCumulative,
            ((uint160(12) << 128) / 100_000) + ((uint160(12) << 128) / 5_000) + ((uint160(12) << 128) / 75_000)
                + ((uint160(8) << 128) / 50_000)
        );
        assertEq(observations[5].tickCumulative, (int64(12) * 1386256) + (-693129 * 12) + (693129 * 12) + (1386256 * 8));
    }

    receive() external payable {}
}

contract OracleTest is BaseOracleTest {
    using CoreLib for *;

    function test_getImmutables() public view {
        assertEq(oracle.timestampOffset(), uint64(block.timestamp));
    }

    function test_createPool_beforeInitializePool() public {
        createOraclePool(address(token1), 1000);
        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));
        assertEq(index, 0);
        assertEq(count, 1);
        assertEq(capacity, 1);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 0);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);
    }

    function test_snapshotEvent_emitted_at_create() public {
        vm.recordLogs();
        createOraclePool(address(token1), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(oracle));
        assertEq(logs[0].topics.length, 0);
        assertEq(logs[0].data.length, 56);
        assertEq(address(bytes20(LibBytes.load(logs[0].data, 0))), address(token1));
        assertEq(uint64(bytes8(LibBytes.load(logs[0].data, 20))), vm.getBlockTimestamp());
        assertEq(uint160(bytes20(LibBytes.load(logs[0].data, 28))), 0);
        assertEq(int64(uint64(bytes8(LibBytes.load(logs[0].data, 48)))), 0);

        assertEq(logs[1].emitter, address(core));
    }

    function test_snapshotEvent_emitted_at_swap() public {
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
        assertEq(log.data.length, 56);
        assertEq(address(bytes20(LibBytes.load(log.data, 0))), address(token1));
        assertEq(uint64(bytes8(LibBytes.load(log.data, 20))), vm.getBlockTimestamp());
        assertEq(uint160(bytes20(LibBytes.load(log.data, 28))), (uint256(5) << 128) / 5000);
        assertEq(int64(uint64(bytes8(LibBytes.load(log.data, 48)))), 5000);

        updateOraclePoolLiquidity(address(token1), 100_000);

        advanceTime(10);

        vm.recordLogs();
        updateOraclePoolLiquidity(address(token1), 1000);
        logs = vm.getRecordedLogs();

        assertEq(logs.length, 4);
        log = logs[1];
        assertEq(log.emitter, address(oracle));
        assertEq(log.topics.length, 0);
        assertEq(log.data.length, 56);
        assertEq(address(bytes20(LibBytes.load(log.data, 0))), address(token1));
        assertEq(uint64(bytes8(LibBytes.load(log.data, 20))), vm.getBlockTimestamp());
        assertEq(
            uint160(bytes20(LibBytes.load(log.data, 28))),
            ((uint256(5) << 128) / 5000) + ((uint256(10) << 128) / 100_000)
        );
        assertEq(int64(uint64(bytes8(LibBytes.load(log.data, 48)))), -25000);
    }

    function test_createPool_beforeInitializePool_first_expandCapacity() public {
        oracle.expandCapacity(address(token1), 10);
        createOraclePool(address(token1), 0);
        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));
        assertEq(index, 0);
        assertEq(count, 1);
        assertEq(capacity, 10);
    }

    function test_createPool_beforeInitializePool_then_expandCapacity() public {
        createOraclePool(address(token1), 0);
        oracle.expandCapacity(address(token1), 10);
        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));
        assertEq(index, 0);
        assertEq(count, 1);
        assertEq(capacity, 10);
    }

    function test_expandCapacity_doesNotOverwrite() public {
        PoolKey memory pk = createOraclePool(address(token1), 2000);
        advanceTime(12);
        movePrice(pk, -500);
        advanceTime(6);
        movePrice(pk, 1000);
        oracle.expandCapacity(address(token1), 2);

        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));
        assertEq(index, 0);
        assertEq(count, 1);
        assertEq(capacity, 2);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 18);
        assertEq(secondsPerLiquidityCumulative, uint256(18) << 128);
        assertEq(tickCumulative, (2000 * 12) + (-500 * 6));

        // empty snapshot initialized
        (secondsSinceOffset, secondsPerLiquidityCumulative, tickCumulative) = oracle.snapshots(address(token1), 1);
        assertEq(secondsSinceOffset, 1);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);
    }

    function test_snapshots_circularWriteAtCapacity() public {
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

        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));
        assertEq(index, 0, "index");
        assertEq(count, 3, "count");
        assertEq(capacity, 3, "capacity");

        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 4 + 6 + 3 + 2);
        assertEq(secondsPerLiquidityCumulative, uint256(4 + 6 + 3 + 2) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));
    }

    function test_snapshots_extrapolateWorksAfterRotate() public {
        uint64 start = uint64(vm.getBlockTimestamp());
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

        vm.expectRevert(abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), start));
        oracle.extrapolateSnapshot(address(token1), start);

        vm.expectRevert(abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), start + 2));
        oracle.extrapolateSnapshot(address(token1), start + 2);

        vm.expectRevert(abi.encodeWithSelector(Oracle.NoPreviousSnapshotExists.selector, address(token1), start + 4));
        oracle.extrapolateSnapshot(address(token1), start + 4);

        (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.extrapolateSnapshot(address(token1), start + 5);
        assertEq(secondsPerLiquidityCumulative, uint256(5) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), start + 6);
        assertEq(secondsPerLiquidityCumulative, uint256(6) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), start + 12);
        assertEq(secondsPerLiquidityCumulative, uint256(12) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), start + 16);
        assertEq(secondsPerLiquidityCumulative, uint256(16) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));

        (secondsPerLiquidityCumulative, tickCumulative) = oracle.extrapolateSnapshot(address(token1), start + 18);
        assertEq(secondsPerLiquidityCumulative, uint256(18) << 128);
        assertEq(tickCumulative, (2000 * 2) + (-500 * 3) + (700 * 6) + (-5000 * 4));

        vm.expectRevert(Oracle.FutureTime.selector);
        oracle.extrapolateSnapshot(address(token1), start + 19);
    }

    function test_createPool_beforeInitializePool_reverts() public {
        vm.expectRevert(Oracle.PairsWithNativeTokenOnly.selector);
        createPool(address(token0), address(token1), 0, 0, FULL_RANGE_ONLY_TICK_SPACING, address(oracle));

        vm.expectRevert(Oracle.TickSpacingMustBeMaximum.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, 0, 100, address(oracle));

        vm.expectRevert(Oracle.FeeMustBeZero.selector);
        createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, 1, FULL_RANGE_ONLY_TICK_SPACING, address(oracle));
    }

    function test_createPosition_failsForPositionsNotWideEnough() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);
        vm.expectRevert(FullRangeOnlyPool.selector);
        positions.mintAndDeposit{value: 100}(
            poolKey, Bounds(-int32(MAX_TICK_SPACING), int32(MAX_TICK_SPACING)), 100, 100, 0
        );
    }

    function test_createPosition() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        advanceTime(30);

        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);
        (uint256 id, uint128 liquidity) = createPosition(poolKey, bounds, 100, 200);
        (uint64 index, uint64 count, uint64 capacity) = oracle.counts(address(token1));

        assertEq(count, 1);
        assertEq(index, 0);
        assertEq(capacity, 1);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 30);
        assertEq(secondsPerLiquidityCumulative, uint160(30) << 128);
        // the tick is flipped so that the price is always oracleToken/token
        assertEq(tickCumulative, 30 * 693147);

        advanceTime(45);
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity);
        assertEq(amount0, 99);
        assertEq(amount1, 199);

        (index, count, capacity) = oracle.counts(address(token1));
        assertEq(count, 1);
        assertEq(index, 0);
        assertEq(capacity, 1);
        (secondsSinceOffset, secondsPerLiquidityCumulative, tickCumulative) = oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 75);
        assertEq(secondsPerLiquidityCumulative, (uint160(30) << 128) + ((uint160(45) << 128) / liquidity));
        assertEq(tickCumulative, 75 * 693147);
    }

    function test_findPreviousSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(vm.getBlockTimestamp());

        oracle.expandCapacity(address(token1), 10);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

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
        assertEq(s.tickCumulative, 10 * 2 * 693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 11);
        assertEq(i, 1);
        assertEq(s.secondsSinceOffset, 15);
        assertEq(s.secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative, 10 * 2 * 693147);

        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 15);
        assertEq(i, 1);
        assertEq(s.secondsSinceOffset, 15);
        assertEq(s.secondsPerLiquidityCumulative, (uint160(10) << 128) / liquidity);
        assertEq(s.tickCumulative, 10 * 2 * 693147);

        // if we pass in a future time it works fine
        (, i, s) = oracle.findPreviousSnapshot(address(token1), poolCreationTime + 100);
        assertEq(i, 2);
        assertEq(s.secondsSinceOffset, 21);
        assertEq(
            s.secondsPerLiquidityCumulative,
            ((uint160(10) << 128) / liquidity) + ((uint160(6) << 128) / (liquidity / 2))
        );
        assertEq(s.tickCumulative, (10 * 2 * 693147) + (693146 / 2 * 6));
    }

    function test_extrapolateSnapshot() public {
        advanceTime(5);
        uint64 poolCreationTime = uint64(block.timestamp);

        oracle.expandCapacity(address(token1), 10);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

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

    function test_getExtrapolatedSnapshots() public {
        uint64 poolCreationTime = advanceTime(5);

        oracle.expandCapacity(address(token1), 5);
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 2000);

        // immediately moved after initialization
        movePrice(poolKey, 693147 * 2);

        advanceTime(10);

        positions.withdraw(id, poolKey, Bounds(MIN_TICK, MAX_TICK), liquidity / 2);

        uint128 liquidity2 = liquidity - (liquidity / 2);

        movePrice(poolKey, 693146 / 2);

        advanceTime(6);

        movePrice(poolKey, 693147);

        advanceTime(5);

        uint64[] memory timestamps = new uint64[](8);
        timestamps[0] = poolCreationTime;
        timestamps[1] = poolCreationTime + 3;
        timestamps[2] = poolCreationTime + 6;
        timestamps[3] = poolCreationTime + 9;
        timestamps[4] = poolCreationTime + 12;
        timestamps[5] = poolCreationTime + 15;
        timestamps[6] = poolCreationTime + 18;
        timestamps[7] = poolCreationTime + 21;
        Oracle.Observation[] memory observations =
            oracle.getExtrapolatedSnapshotsForSortedTimestamps(address(token1), timestamps);

        vm.snapshotGasLastCall("oracle.getExtrapolatedSnapshots(address(token1), 21, 3, 8)");

        assertEq(observations.length, timestamps.length);

        // liquidity
        assertEq(observations[0].secondsPerLiquidityCumulative, 0);
        assertEq(observations[1].secondsPerLiquidityCumulative, (uint256(3) << 128) / liquidity);
        assertEq(observations[2].secondsPerLiquidityCumulative, (uint256(6) << 128) / liquidity);
        assertEq(observations[3].secondsPerLiquidityCumulative, (uint256(9) << 128) / liquidity);
        assertEq(
            observations[4].secondsPerLiquidityCumulative,
            ((uint256(10) << 128) / liquidity) + ((uint256(2) << 128) / liquidity2)
        );
        assertEq(
            observations[5].secondsPerLiquidityCumulative,
            ((uint256(10) << 128) / liquidity) + ((uint256(5) << 128) / liquidity2)
        );
        assertEq(
            observations[6].secondsPerLiquidityCumulative,
            // rounded down
            ((uint256(10) << 128) / liquidity) + ((uint256(8) << 128) / liquidity2) - 1
        );
        assertEq(
            observations[7].secondsPerLiquidityCumulative,
            // rounded down
            ((uint256(10) << 128) / liquidity) + ((uint256(11) << 128) / liquidity2) - 1
        );

        // ticks always expressed in oracle token / token
        assertEq(observations[0].tickCumulative, 0);
        assertEq(observations[1].tickCumulative, (693147 * 2) * 3);
        assertEq(observations[2].tickCumulative, (693147 * 2) * 6);
        assertEq(observations[3].tickCumulative, (693147 * 2) * 9);
        assertEq(observations[4].tickCumulative, (693147 * 2) * 10 + ((346573) * 2));
        assertEq(observations[5].tickCumulative, (693147 * 2) * 10 + ((346573) * 5));
        assertEq(observations[6].tickCumulative, (693147 * 2) * 10 + ((346573) * 6) + (693147 * 2));
        assertEq(observations[7].tickCumulative, (693147 * 2) * 10 + ((346573) * 6) + (693147 * 5));
    }

    function test_cannotCallExtensionMethodsDirectly() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeInitializePool(address(0), poolKey, 15);

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeUpdatePosition(address(0), poolKey, UpdatePositionParameters(bytes32(0x0), Bounds(-100, 100), 0));

        vm.expectRevert(UsesCore.CoreOnly.selector);
        oracle.beforeSwap(address(0), poolKey, SwapParameters(0, false, 0, 0));
    }

    function test_gas_swap_on_oracle_pool() public {
        PoolKey memory poolKey = createOraclePool(address(token1), 693147);
        updateOraclePoolLiquidity(address(token1), 1e18);

        TestToken(poolKey.token1).approve(address(router), type(uint256).max);

        advanceTime(1);
        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);

        advanceTime(1);
        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token1 in with write");

        advanceTime(1);
        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token0 in with write");

        router.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token1 in no write");

        router.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("swap token0 in no write");
    }

    receive() external payable {}
}
