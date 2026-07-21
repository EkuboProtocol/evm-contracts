// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {Ve33Periphery} from "../../src/Ve33Periphery.sol";
import {Ve33, ve33CallPoints} from "../../src/extensions/Ve33.sol";
import {
    Ve33DataFetcher,
    Ve33EmissionRateChange,
    Ve33EmissionState,
    Ve33QuoteData
} from "../../src/lens/Ve33DataFetcher.sol";
import {Ve33Lib} from "../../src/libraries/Ve33Lib.sol";
import {Ve33StorageLayout} from "../../src/libraries/Ve33StorageLayout.sol";
import {nextValidTime} from "../../src/math/time.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {createVePoolSwapFeeState, VePoolSwapFeeState} from "../../src/types/vePoolSwapFeeState.sol";

contract Ve33DataFetcherTest is FullTest {
    using Ve33Lib for Ve33;

    Ve33 internal ve;
    Ve33Periphery internal periphery;
    Ve33DataFetcher internal dataFetcher;
    TestToken internal stakeToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));
        periphery = new Ve33Periphery(core, ve);
        dataFetcher = new Ve33DataFetcher(core, ve);

        stakeToken.approve(address(periphery), type(uint256).max);
    }

    function _nextValidEmissionTime(uint256 afterTime) internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), afterTime));
    }

    function _expectedEmissions(uint256 rate, uint256 startTime, uint256 endTime) internal pure returns (uint256) {
        return (rate * (endTime - startTime)) >> 32;
    }

    function test_getEmissionState_empty() public {
        vm.warp(1);

        Ve33EmissionState memory state = dataFetcher.getEmissionState();

        assertEq(state.currentTimestamp, vm.getBlockTimestamp());
        assertEq(state.currentEmissionRate, 0);
        assertEq(state.totalRemainingEmissions, 0);
        assertEq(state.futureEmissionRateChanges.length, 0);
    }

    function test_getPoolSwapFees() public {
        PoolId[] memory poolIds = new PoolId[](3);
        poolIds[0] = PoolId.wrap(bytes32(uint256(1)));
        poolIds[1] = PoolId.wrap(bytes32(uint256(2)));
        poolIds[2] = PoolId.wrap(bytes32(uint256(3)));

        VePoolSwapFeeState state0 = createVePoolSwapFeeState(100, uint64(1 << 60));
        VePoolSwapFeeState state2 = createVePoolSwapFeeState(300, uint64(3 << 60));
        vm.store(
            address(ve),
            StorageSlot.unwrap(Ve33StorageLayout.poolSwapFeeStateSlot(poolIds[0])),
            VePoolSwapFeeState.unwrap(state0)
        );
        vm.store(
            address(ve),
            StorageSlot.unwrap(Ve33StorageLayout.poolSwapFeeStateSlot(poolIds[2])),
            VePoolSwapFeeState.unwrap(state2)
        );

        uint64[] memory swapFees = dataFetcher.getPoolSwapFees(poolIds);

        assertEq(swapFees.length, 3);
        assertEq(swapFees[0], uint64(1 << 60));
        assertEq(swapFees[1], 0);
        assertEq(swapFees[2], uint64(3 << 60));
    }

    function test_getVe33QuoteData() public {
        PoolKey memory poolKey = createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 10,
            config: createConcentratedPoolConfig(0, 4, address(ve))
        });
        (, uint128 liquidity) = createPosition(poolKey, -40, 40, 1_000, 1_000);
        uint64 swapFee = uint64(1 << 60);
        vm.store(
            address(ve),
            StorageSlot.unwrap(Ve33StorageLayout.poolSwapFeeStateSlot(poolKey.toPoolId())),
            VePoolSwapFeeState.unwrap(createVePoolSwapFeeState(100, swapFee))
        );

        PoolKey[] memory poolKeys = new PoolKey[](1);
        poolKeys[0] = poolKey;
        Ve33QuoteData[] memory quoteData = dataFetcher.getVe33QuoteData(poolKeys, 1);

        assertEq(quoteData.length, 1);
        assertEq(quoteData[0].swapFee, swapFee);
        assertEq(quoteData[0].quoteData.tick, 10);
        assertEq(quoteData[0].quoteData.liquidity, liquidity);
        assertEq(quoteData[0].quoteData.ticks.length, 2);
        assertEq(quoteData[0].quoteData.ticks[0].number, -40);
        assertEq(quoteData[0].quoteData.ticks[1].number, 40);
    }

    function test_getVe33QuoteData_revertsForNonVe33Pool() public {
        PoolKey memory poolKey = createPool({tick: 10, fee: 0, tickSpacing: 4});
        PoolKey[] memory poolKeys = new PoolKey[](1);
        poolKeys[0] = poolKey;

        vm.expectRevert(abi.encodeWithSelector(Ve33DataFetcher.InvalidVe33Pool.selector, poolKey.toPoolId()));
        dataFetcher.getVe33QuoteData(poolKeys, 1);
    }

    function test_getEmissionState_immediateSchedule() public {
        vm.warp(1);

        uint64 endTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1 weeks - 1);
        uint160 rate = uint160(3 << 32);
        periphery.scheduleEmissions(0, endTime, rate);

        Ve33EmissionState memory state = dataFetcher.getEmissionState();

        assertEq(state.currentTimestamp, vm.getBlockTimestamp());
        assertEq(state.currentEmissionRate, rate);
        assertEq(state.totalRemainingEmissions, _expectedEmissions(rate, vm.getBlockTimestamp(), endTime));
        assertEq(state.futureEmissionRateChanges.length, 1);

        Ve33EmissionRateChange memory change = state.futureEmissionRateChanges[0];
        assertEq(change.time, endTime);
        assertEq(change.emissionRateDelta, -int256(uint256(rate)));
        assertEq(change.emissionRateAfter, 0);
    }

    function test_getEmissionState_aggregatesSameTimeChanges() public {
        vm.warp(1);

        uint64 endTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1 weeks - 1);
        uint160 rate0 = uint160(2 << 32);
        uint160 rate1 = uint160(5 << 32);
        uint256 totalRate = uint256(rate0) + uint256(rate1);
        periphery.scheduleEmissions(0, endTime, rate0);
        periphery.scheduleEmissions(0, endTime, rate1);

        Ve33EmissionState memory state = dataFetcher.getEmissionState();

        assertEq(state.currentEmissionRate, totalRate);
        assertEq(state.totalRemainingEmissions, _expectedEmissions(totalRate, vm.getBlockTimestamp(), endTime));
        assertEq(state.futureEmissionRateChanges.length, 1);
        assertEq(state.futureEmissionRateChanges[0].time, endTime);
        assertEq(state.futureEmissionRateChanges[0].emissionRateDelta, -int256(totalRate));
        assertEq(state.futureEmissionRateChanges[0].emissionRateAfter, 0);
    }

    function test_getEmissionState_appliesElapsedChangesWithoutMutatingVe33() public {
        vm.warp(1);

        uint64 startTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1_000);
        uint64 endTime = _nextValidEmissionTime(startTime);
        uint256 realStartTime = startTime;
        uint256 realEndTime = endTime;
        uint160 rate = uint160(7 << 32);
        periphery.scheduleEmissions(startTime, endTime, rate);

        Ve33EmissionState memory beforeStart = dataFetcher.getEmissionState();
        assertEq(beforeStart.currentEmissionRate, 0);
        assertEq(beforeStart.totalRemainingEmissions, _expectedEmissions(rate, realStartTime, realEndTime));
        assertEq(beforeStart.futureEmissionRateChanges.length, 2);
        assertEq(beforeStart.futureEmissionRateChanges[0].time, startTime);
        assertEq(beforeStart.futureEmissionRateChanges[0].emissionRateDelta, int256(uint256(rate)));
        assertEq(beforeStart.futureEmissionRateChanges[0].emissionRateAfter, rate);
        assertEq(beforeStart.futureEmissionRateChanges[1].time, endTime);
        assertEq(beforeStart.futureEmissionRateChanges[1].emissionRateDelta, -int256(uint256(rate)));
        assertEq(beforeStart.futureEmissionRateChanges[1].emissionRateAfter, 0);

        vm.warp(startTime);

        Ve33EmissionState memory atStart = dataFetcher.getEmissionState();
        assertEq(ve.emissionRate(), 0);
        assertEq(atStart.currentTimestamp, startTime);
        assertEq(atStart.currentEmissionRate, rate);
        assertEq(atStart.totalRemainingEmissions, _expectedEmissions(rate, realStartTime, realEndTime));
        assertEq(atStart.futureEmissionRateChanges.length, 1);
        assertEq(atStart.futureEmissionRateChanges[0].time, endTime);
        assertEq(atStart.futureEmissionRateChanges[0].emissionRateDelta, -int256(uint256(rate)));
        assertEq(atStart.futureEmissionRateChanges[0].emissionRateAfter, 0);
    }
}
