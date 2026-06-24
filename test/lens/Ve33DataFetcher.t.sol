// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {Ve33Periphery} from "../../src/Ve33Periphery.sol";
import {Ve33, ve33CallPoints} from "../../src/extensions/Ve33.sol";
import {Ve33DataFetcher, Ve33EmissionRateChange, Ve33EmissionState} from "../../src/lens/Ve33DataFetcher.sol";
import {Ve33Lib} from "../../src/libraries/Ve33Lib.sol";
import {nextValidTime} from "../../src/math/time.sol";

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
        deployCodeTo("Ve33.sol", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));
        periphery = new Ve33Periphery(core, ve);
        dataFetcher = new Ve33DataFetcher(ve);

        stakeToken.approve(address(periphery), type(uint256).max);
    }

    function _nextValidEmissionTime(uint256 afterTime) internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), afterTime));
    }

    function _expectedEmissions(uint256 rate, uint64 startTime, uint64 endTime) internal pure returns (uint256) {
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

    function test_getEmissionState_immediateSchedule() public {
        vm.warp(1);

        uint64 endTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1 weeks - 1);
        uint224 rate = uint224(3 << 32);
        periphery.scheduleEmissions(0, endTime, rate);

        Ve33EmissionState memory state = dataFetcher.getEmissionState();

        assertEq(state.currentTimestamp, vm.getBlockTimestamp());
        assertEq(state.currentEmissionRate, rate);
        assertEq(state.totalRemainingEmissions, _expectedEmissions(rate, uint64(vm.getBlockTimestamp()), endTime));
        assertEq(state.futureEmissionRateChanges.length, 1);

        Ve33EmissionRateChange memory change = state.futureEmissionRateChanges[0];
        assertEq(change.time, endTime);
        assertEq(change.emissionRateDelta, -int256(uint256(rate)));
        assertEq(change.emissionRateAfter, 0);
    }

    function test_getEmissionState_aggregatesSameTimeChanges() public {
        vm.warp(1);

        uint64 endTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1 weeks - 1);
        uint224 rate0 = uint224(2 << 32);
        uint224 rate1 = uint224(5 << 32);
        uint256 totalRate = uint256(rate0) + uint256(rate1);
        periphery.scheduleEmissions(0, endTime, rate0);
        periphery.scheduleEmissions(0, endTime, rate1);

        Ve33EmissionState memory state = dataFetcher.getEmissionState();

        assertEq(state.currentEmissionRate, totalRate);
        assertEq(state.totalRemainingEmissions, _expectedEmissions(totalRate, uint64(vm.getBlockTimestamp()), endTime));
        assertEq(state.futureEmissionRateChanges.length, 1);
        assertEq(state.futureEmissionRateChanges[0].time, endTime);
        assertEq(state.futureEmissionRateChanges[0].emissionRateDelta, -int256(totalRate));
        assertEq(state.futureEmissionRateChanges[0].emissionRateAfter, 0);
    }

    function test_getEmissionState_appliesElapsedChangesWithoutMutatingVe33() public {
        vm.warp(1);

        uint64 startTime = _nextValidEmissionTime(vm.getBlockTimestamp() + 1_000);
        uint64 endTime = _nextValidEmissionTime(startTime);
        uint224 rate = uint224(7 << 32);
        periphery.scheduleEmissions(startTime, endTime, rate);

        Ve33EmissionState memory beforeStart = dataFetcher.getEmissionState();
        assertEq(beforeStart.currentEmissionRate, 0);
        assertEq(beforeStart.totalRemainingEmissions, _expectedEmissions(rate, startTime, endTime));
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
        assertEq(atStart.totalRemainingEmissions, _expectedEmissions(rate, startTime, endTime));
        assertEq(atStart.futureEmissionRateChanges.length, 1);
        assertEq(atStart.futureEmissionRateChanges[0].time, endTime);
        assertEq(atStart.futureEmissionRateChanges[0].emissionRateDelta, -int256(uint256(rate)));
        assertEq(atStart.futureEmissionRateChanges[0].emissionRateAfter, 0);
    }
}
