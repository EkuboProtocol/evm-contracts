// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";

import {FullTest} from "./FullTest.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {computeStepSize, isTimeValid, nextValidTime} from "../src/math/time.sol";
import {ScheduledVe33EmissionRateConfig} from "../src/types/scheduledVe33EmissionRateConfig.sol";
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";

contract SchedulerCallRevertTarget {
    error SchedulerTestError(uint256 value);

    function fail(uint256 value) external pure {
        revert SchedulerTestError(value);
    }
}

contract Ve33EmissionRateSchedulerTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint32 private constant SCHEDULE_DURATION = 1 weeks;
    uint160 private constant MIN_EMISSIONS_RATE = uint160(uint256(1e12) << 32);
    uint160 private constant DOUBLE_MIN_EMISSIONS_RATE = MIN_EMISSIONS_RATE * 2;

    uint128 private constant INITIAL_DAILY_EMISSION_AMOUNT = 333_333e16;
    uint128 private constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint160 private constant INITIAL_EMISSION_RATE =
        uint160(((uint256(INITIAL_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);
    uint128 private constant ONGOING_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 private constant ONGOING_EMISSION_RATE =
        uint160(((uint256(ONGOING_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);
    uint128 private constant SCHEDULER_FUNDING = type(uint128).max;

    MintableERC20 internal stakeToken;
    Ve33 internal ve;
    Ve33EmissionRateScheduler internal scheduler;

    function setUp() public override {
        super.setUp();

        stakeToken = new MintableERC20(address(this), "Mintable TestToken", "mTT", 18);
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));

        scheduler = new Ve33EmissionRateScheduler(owner, core, ve);
        stakeToken.mint(address(scheduler), SCHEDULER_FUNDING);
    }

    function test_constructorInitializesTokenAndPolicyCursor() public view {
        assertEq(scheduler.stakeToken(), address(stakeToken));
        assertEq(stakeToken.owner(), address(this));
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING);
        assertEq(scheduler.lastScheduledTime(), block.timestamp);
        assertEq(scheduler.emissionEnd(), 0);
        assertEq(scheduler.config().nextConfigTime(), 0);
    }

    function test_setConfigFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
    }

    function test_setConfigFailsWithNonzeroMinEmissionsRateAndZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(Ve33EmissionRateScheduler.InvalidScheduleDuration.selector);
        scheduler.setConfig(MIN_EMISSIONS_RATE, 0);
    }

    function test_setConfigPacksMinEmissionsRateAndScheduleDuration() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);

        Ve33EmissionRateConfig config = scheduler.config().emissionRateConfig();
        assertEq(config.minEmissionsRate(), MIN_EMISSIONS_RATE);
        assertEq(config.scheduleDuration(), SCHEDULE_DURATION);
        assertEq(scheduler.lastScheduledTime(), block.timestamp);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_multicallBatchesOwnerConfiguration() public {
        uint64 startTime = uint64(block.timestamp + 1 days);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(scheduler.setConfig, (MIN_EMISSIONS_RATE, SCHEDULE_DURATION));
        calls[1] = abi.encodeCall(
            scheduler.scheduleConfig, (startTime, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, uint64(0))
        );

        vm.prank(owner);
        bytes[] memory results = scheduler.multicall(calls);

        assertEq(results.length, 2);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), MIN_EMISSIONS_RATE);
        assertEq(scheduler.config().nextConfigTime(), startTime);
        _assertScheduledConfig(startTime, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_multicallRejectsNonzeroValue() public {
        bytes[] memory calls = new bytes[](0);
        vm.deal(address(this), 1);

        vm.expectRevert();
        scheduler.multicall{value: 1}(calls);
    }

    function test_setConfigFailsAfterFuturePolicyWasScheduled() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
        scheduler.mintAndSchedule();
        uint64 accountedUntil = scheduler.lastScheduledTime();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Ve33EmissionRateScheduler.EmissionsAlreadyScheduled.selector, accountedUntil)
        );
        scheduler.setConfig(DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
    }

    function test_setConfigFailsInsteadOfSkippingDueQueuedConfig() public {
        uint64 startTime = uint64(block.timestamp + 1 days);
        _scheduleConfig(startTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
        vm.warp(startTime);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.ConfigUpdateDue.selector, startTime));
        scheduler.setConfig(DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
    }

    function test_mintAndScheduleReturnsZeroWhenUnconfigured() public {
        uint64 initialCursor = scheduler.lastScheduledTime();

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), initialCursor);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING);
    }

    function test_zeroRateAdvancesPolicyWithoutPayment() public {
        _setConfig(0, SCHEDULE_DURATION);
        uint64 policyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint64 validEnd = _validTimeAtOrAfter(policyEnd);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), policyEnd);
        assertEq(scheduler.emissionEnd(), validEnd);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING);
        assertEq(ve.emissionRate(), 0);
    }

    function test_lockCallbackFailsIfNotCore() public {
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        scheduler.locked_6416899205(0);
    }

    function test_mintAndSchedulePaysExactPolicyAmountFromBalanceIntoValidInterval() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);

        uint64 policyStart = uint64(block.timestamp);
        uint64 policyEnd = policyStart + SCHEDULE_DURATION;
        uint64 validEnd = _validTimeAtOrBefore(policyEnd);
        uint128 expectedAmount = uint128(uint256(SCHEDULE_DURATION) * 1e12);
        uint160 fittedRate = uint160((uint256(expectedAmount) << 32) / (validEnd - policyStart));

        uint128 amount = scheduler.mintAndSchedule();

        assertEq(amount, expectedAmount);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - expectedAmount);
        assertEq(stakeToken.totalSupply(), SCHEDULER_FUNDING);
        assertEq(stakeToken.balanceOf(address(core)), expectedAmount);
        assertEq(_rewardSavedBalance(), expectedAmount);
        assertEq(scheduler.lastScheduledTime(), policyEnd);
        assertEq(scheduler.emissionEnd(), validEnd);
        assertEq(scheduler.rateRemainder(), 0);
        assertEq(ve.emissionRate(), fittedRate);
        assertEq(ve.emissionRateDeltaAtTime(validEnd), -int256(uint256(fittedRate)));
        assertTrue(isTimeValid(policyStart, validEnd));
    }

    function test_mintAndScheduleRevertsAtomicallyWhenSchedulerIsUnderfunded() public {
        Ve33EmissionRateScheduler unfundedScheduler = new Ve33EmissionRateScheduler(owner, core, ve);
        vm.prank(owner);
        unfundedScheduler.setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
        uint64 initialPolicyCursor = unfundedScheduler.lastScheduledTime();
        uint64 initialEmissionEnd = unfundedScheduler.emissionEnd();

        vm.expectRevert();
        unfundedScheduler.mintAndSchedule();

        assertEq(unfundedScheduler.lastScheduledTime(), initialPolicyCursor);
        assertEq(unfundedScheduler.emissionEnd(), initialEmissionEnd);
        assertEq(ve.emissionRate(), 0);
        assertEq(_rewardSavedBalance(), 0);
    }

    function test_mintAndScheduleOnlyFundsShortfallBelowMinimum() public {
        uint160 existingRate = MIN_EMISSIONS_RATE / 4;
        _scheduleExternalEmissions(existingRate, _validTimeAtOrAfter(uint64(block.timestamp + 2 weeks)));
        uint256 balanceBefore = stakeToken.balanceOf(address(scheduler));
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);

        uint64 nowTime = uint64(block.timestamp);
        uint128 policyAmount = uint128(uint256(SCHEDULE_DURATION) * 1e12);
        uint64 expectedEnd = _validTimeAtOrBefore(nowTime + SCHEDULE_DURATION);
        uint160 fittedMinRate = uint160((uint256(policyAmount) << 32) / (expectedEnd - nowTime));
        uint160 shortfall = fittedMinRate - existingRate;
        uint128 expectedAmount = uint128((((expectedEnd - nowTime) * uint256(shortfall)) + type(uint32).max) >> 32);

        uint128 amount = scheduler.mintAndSchedule();

        assertEq(amount, expectedAmount);
        assertEq(stakeToken.balanceOf(address(scheduler)), balanceBefore - amount);
        assertEq(stakeToken.totalSupply(), SCHEDULER_FUNDING);
        assertEq(ve.emissionRate(), fittedMinRate);
        assertGe(ve.emissionRate(), MIN_EMISSIONS_RATE);
        assertLt(amount, policyAmount);
    }

    function test_mintAndSchedulePaysNothingWhenExistingRateIsAtMinimum() public {
        _scheduleExternalEmissions(MIN_EMISSIONS_RATE, _validTimeAtOrAfter(uint64(block.timestamp + 2 weeks)));
        uint256 balanceBefore = stakeToken.balanceOf(address(scheduler));
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.balanceOf(address(scheduler)), balanceBefore);
        assertEq(ve.emissionRate(), MIN_EMISSIONS_RATE);
        assertEq(scheduler.lastScheduledTime(), block.timestamp + SCHEDULE_DURATION);
    }

    function test_mintAndScheduleDoesNotDoubleScheduleSamePolicyHorizon() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();

        assertGt(firstAmount, 0);
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - firstAmount);
    }

    function test_mintAndScheduleAppendsAfterExistingValidEmissionEnd() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);

        uint64 initialTime = uint64(block.timestamp);
        uint128 firstAmount = scheduler.mintAndSchedule();
        uint64 firstPolicyEnd = initialTime + SCHEDULE_DURATION;
        uint64 firstEmissionEnd = scheduler.emissionEnd();

        vm.warp(initialTime + 3 days);

        uint64 secondPolicyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint128 expectedSecondAmount = uint128(uint256(secondPolicyEnd - firstPolicyEnd) * 1e12);
        uint64 realSecondStart = firstEmissionEnd > block.timestamp ? firstEmissionEnd : uint64(block.timestamp);
        uint64 expectedSecondEnd = _validTimeAtOrBefore(realSecondStart + (secondPolicyEnd - firstPolicyEnd));

        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, expectedSecondAmount);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - uint256(firstAmount) - secondAmount);
        assertEq(scheduler.lastScheduledTime(), secondPolicyEnd);
        assertEq(scheduler.emissionEnd(), expectedSecondEnd);
        assertGt(expectedSecondEnd, firstEmissionEnd);
        assertTrue(isTimeValid(block.timestamp, expectedSecondEnd));
    }

    function test_mintAndScheduleCarriesFractionalQ32Amounts() public {
        uint160 oneThirdWeiPerSecond = uint160((uint256(1) << 32) / 3);
        uint32 duration = 1 days;
        _setConfig(oneThirdWeiPerSecond, duration);

        uint128 firstAmount = scheduler.mintAndSchedule();
        uint32 firstRemainder = scheduler.rateRemainder();
        assertEq(firstAmount, (uint256(duration) * oneThirdWeiPerSecond) >> 32);
        assertEq(firstRemainder, uint32(uint256(duration) * oneThirdWeiPerSecond));

        vm.warp(block.timestamp + duration);

        uint128 secondAmount = scheduler.mintAndSchedule();
        assertEq(uint256(firstAmount) + secondAmount, (uint256(duration) * 2 * oneThirdWeiPerSecond) >> 32);
        assertEq(
            scheduler.rateRemainder(),
            uint32(uint256(duration) * 2 * oneThirdWeiPerSecond),
            "two durations of Q32 remainder"
        );
    }

    function test_mintAndScheduleRejectsPolicyAmountAboveUint128() public {
        _setConfig(type(uint160).max, type(uint32).max);

        vm.expectRevert(Ve33EmissionRateScheduler.EmissionAmountOverflow.selector);
        scheduler.mintAndSchedule();
    }

    function test_scheduleConfigFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.scheduleConfig(uint64(block.timestamp + 1 days), MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigFailsWithZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(Ve33EmissionRateScheduler.InvalidScheduleDuration.selector);
        scheduler.scheduleConfig(uint64(block.timestamp + 1 days), MIN_EMISSIONS_RATE, 0, 0);
    }

    function test_scheduleConfigFailsAtAccountedTimestamp() public {
        uint64 accountedTime = scheduler.lastScheduledTime();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, accountedTime));
        scheduler.scheduleConfig(accountedTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigInsertsWithLinkedListHints() public {
        uint64 time10 = uint64(block.timestamp + 10 days);
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);

        _scheduleConfig(time30, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time10, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time20, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time10);

        assertEq(scheduler.config().nextConfigTime(), time10);
        _assertScheduledConfig(time10, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time20);
        _assertScheduledConfig(time20, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time30);
        _assertScheduledConfig(time30, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigRejectsDuplicateTimestamp() public {
        uint64 startTime = uint64(block.timestamp + 10 days);
        _scheduleConfig(startTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.ConfigAlreadyScheduled.selector, startTime));
        scheduler.scheduleConfig(startTime, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigRejectsIncorrectInsertionHint() public {
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);
        _scheduleConfig(time30, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidPreviousConfigTime.selector, time30));
        scheduler.scheduleConfig(time20, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time30);
    }

    function test_scheduleConfigRejectsAlreadyAccountedFutureTime() public {
        _setConfig(0, SCHEDULE_DURATION);
        scheduler.mintAndSchedule();
        uint64 accountedTime = scheduler.lastScheduledTime();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, accountedTime));
        scheduler.scheduleConfig(accountedTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
    }

    function test_cancelConfigRemovesHeadAndMiddleNodes() public {
        uint64 time10 = uint64(block.timestamp + 10 days);
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);
        _scheduleConfig(time10, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time20, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time10);
        _scheduleConfig(time30, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time20);

        vm.prank(owner);
        scheduler.cancelConfig(time20, time10);
        _assertScheduledConfig(time10, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, time30);
        _assertScheduledConfig(time20, 0, 0, 0);

        vm.prank(owner);
        scheduler.cancelConfig(time10, 0);
        assertEq(scheduler.config().nextConfigTime(), time30);
        _assertScheduledConfig(time10, 0, 0, 0);
    }

    function test_cancelConfigRejectsIncorrectHint() public {
        uint64 startTime = uint64(block.timestamp + 10 days);
        _scheduleConfig(startTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidPreviousConfigTime.selector, startTime));
        scheduler.cancelConfig(startTime, startTime);
    }

    function test_cancelConfigRejectsMissingConfig() public {
        uint64 startTime = uint64(block.timestamp + 10 days);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.ConfigNotScheduled.selector, startTime));
        scheduler.cancelConfig(startTime, 0);
    }

    function test_cancelConfigRejectsConfigWhoseStartTimeWasReached() public {
        uint64 startTime = uint64(block.timestamp + 10 days);
        _scheduleConfig(startTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);
        vm.warp(startTime);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, startTime));
        scheduler.cancelConfig(startTime, 0);
    }

    function test_arbitraryConfigStartDoesNotPayBeforePolicyStart() public {
        _setConfig(0, SCHEDULE_DURATION);
        uint64 policyStart = uint64(block.timestamp + 3 days + 123);
        assertFalse(isTimeValid(block.timestamp, policyStart));
        _scheduleConfig(policyStart, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), policyStart);
        assertEq(scheduler.config().nextConfigTime(), 0);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), MIN_EMISSIONS_RATE);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING);
        assertEq(ve.emissionRate(), 0);

        uint64 fittedStart = scheduler.emissionEnd();
        assertGe(fittedStart, policyStart);
        assertTrue(isTimeValid(block.timestamp, fittedStart));

        uint64 policyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint128 expectedAmount = uint128(uint256(policyEnd - policyStart) * 1e12);
        assertEq(scheduler.mintAndSchedule(), expectedAmount);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - expectedAmount);
        assertEq(ve.emissionRate(), 0);

        int256 startRateDelta = ve.emissionRateDeltaAtTime(fittedStart);
        assertGt(startRateDelta, 0);
        vm.warp(fittedStart);
        ve.accrueEmissions();
        assertEq(ve.emissionRate(), uint160(uint256(startRateDelta)));
    }

    function test_mintAndScheduleStopsAtArbitraryNextConfigBoundary() public {
        _setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
        uint64 policyStart = uint64(block.timestamp);
        uint64 updateTime = policyStart + 3 days + 123;
        _scheduleConfig(updateTime, DOUBLE_MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        uint128 firstExpectedAmount = uint128(uint256(updateTime - policyStart) * 1e12);
        assertEq(scheduler.mintAndSchedule(), firstExpectedAmount);
        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - firstExpectedAmount);
        assertEq(scheduler.lastScheduledTime(), updateTime);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), DOUBLE_MIN_EMISSIONS_RATE);
        assertEq(scheduler.rateRemainder(), 0);

        uint64 secondPolicyEnd = policyStart + SCHEDULE_DURATION;
        uint128 secondExpectedAmount = uint128(uint256(secondPolicyEnd - updateTime) * 2e12);
        assertEq(scheduler.mintAndSchedule(), secondExpectedAmount);
        assertEq(
            stakeToken.balanceOf(address(scheduler)),
            SCHEDULER_FUNDING - uint256(firstExpectedAmount) - secondExpectedAmount
        );
    }

    function test_configActivationResetsPriorRateRemainder() public {
        uint160 oneThirdWeiPerSecond = uint160((uint256(1) << 32) / 3);
        _setConfig(oneThirdWeiPerSecond, SCHEDULE_DURATION);
        uint64 updateTime = uint64(block.timestamp + 2);
        _scheduleConfig(updateTime, MIN_EMISSIONS_RATE, SCHEDULE_DURATION, 0);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), updateTime);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), MIN_EMISSIONS_RATE);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_weeklyPokesPayExactly333333TokensAcrossFirst100Days() public {
        _setConfig(0, SCHEDULE_DURATION);

        uint64 initialStart = uint64(block.timestamp + 1 weeks + 123);
        uint64 initialEnd = initialStart + 100 days;
        _scheduleConfig(initialStart, INITIAL_EMISSION_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(initialEnd, ONGOING_EMISSION_RATE, SCHEDULE_DURATION, initialStart);

        assertEq((uint256(100 days) * INITIAL_EMISSION_RATE) >> 32, INITIAL_EMISSION_AMOUNT);
        assertEq(scheduler.mintAndSchedule(), 0);

        vm.warp(initialStart);
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), INITIAL_EMISSION_RATE);

        assertGt(scheduler.mintAndSchedule(), 0);
        for (uint256 week = 1; week < 14; week++) {
            vm.warp(initialStart + week * 1 weeks);
            assertGt(scheduler.mintAndSchedule(), 0);
        }

        vm.warp(initialStart + 14 weeks);
        assertGt(scheduler.mintAndSchedule(), 0);

        assertEq(stakeToken.balanceOf(address(scheduler)), SCHEDULER_FUNDING - INITIAL_EMISSION_AMOUNT);
        assertEq(stakeToken.totalSupply(), SCHEDULER_FUNDING);
        assertEq(_rewardSavedBalance(), INITIAL_EMISSION_AMOUNT);
        assertEq(scheduler.lastScheduledTime(), initialEnd);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), ONGOING_EMISSION_RATE);
        assertEq(scheduler.config().nextConfigTime(), 0);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_callForwardsArbitraryCallFromOwner() public {
        vm.prank(owner);
        bytes memory result = scheduler.call(address(stakeToken), 0, abi.encodeWithSignature("owner()"));
        assertEq(abi.decode(result, (address)), address(this));
    }

    function test_callFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.call(address(0), 0, "");
    }

    function test_callBubblesRevert() public {
        SchedulerCallRevertTarget target = new SchedulerCallRevertTarget();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SchedulerCallRevertTarget.SchedulerTestError.selector, 42));
        scheduler.call(address(target), 0, abi.encodeCall(SchedulerCallRevertTarget.fail, (42)));
    }

    function _setConfig(uint160 minEmissionsRate, uint32 scheduleDuration) private {
        vm.prank(owner);
        scheduler.setConfig(minEmissionsRate, scheduleDuration);
    }

    function _scheduleConfig(
        uint64 startTime,
        uint160 minEmissionsRate,
        uint32 scheduleDuration,
        uint64 previousConfigTime
    ) private {
        vm.prank(owner);
        scheduler.scheduleConfig(startTime, minEmissionsRate, scheduleDuration, previousConfigTime);
    }

    function _assertScheduledConfig(
        uint64 startTime,
        uint160 expectedRate,
        uint32 expectedDuration,
        uint64 expectedNextTime
    ) private view {
        ScheduledVe33EmissionRateConfig scheduledConfig = scheduler.scheduledConfigs(startTime);
        assertEq(scheduledConfig.emissionRateConfig().minEmissionsRate(), expectedRate);
        assertEq(scheduledConfig.emissionRateConfig().scheduleDuration(), expectedDuration);
        assertEq(scheduledConfig.nextConfigTime(), expectedNextTime);
    }

    function _validTimeAtOrAfter(uint64 minimumTime) private view returns (uint64) {
        return uint64(nextValidTime(block.timestamp, uint256(minimumTime) - 1));
    }

    function _validTimeAtOrBefore(uint64 maximumTime) private view returns (uint64) {
        uint256 stepSize = computeStepSize(block.timestamp, maximumTime);
        return maximumTime - (maximumTime % uint64(stepSize));
    }

    function _scheduleExternalEmissions(uint160 rate, uint64 endTime) private returns (uint128 amount) {
        Ve33Periphery periphery = new Ve33Periphery(core, ve);
        amount = uint128((((endTime - block.timestamp) * uint256(rate)) + type(uint32).max) >> 32);

        vm.startPrank(owner);
        scheduler.call(
            address(stakeToken), 0, abi.encodeCall(stakeToken.approve, (address(periphery), uint256(amount)))
        );
        scheduler.call(address(periphery), 0, abi.encodeCall(periphery.scheduleEmissions, (uint64(0), endTime, rate)));
        vm.stopPrank();
    }

    function _rewardSavedBalance() private view returns (uint128 saved) {
        (saved,) = core.savedBalances(
            address(ve), address(stakeToken), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
    }
}

contract Ve33EmissionRateSchedulerNativeTest is FullTest {
    using CoreLib for *;

    uint32 private constant SCHEDULE_DURATION = 1 days;
    uint160 private constant MIN_EMISSIONS_RATE = uint160(1 << 32);

    Ve33 private ve;
    Ve33EmissionRateScheduler private scheduler;

    function setUp() public override {
        super.setUp();

        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, NATIVE_TOKEN_ADDRESS), deployAddress);
        ve = Ve33(payable(deployAddress));
        scheduler = new Ve33EmissionRateScheduler(owner, core, ve);

        vm.prank(owner);
        scheduler.setConfig(MIN_EMISSIONS_RATE, SCHEDULE_DURATION);
    }

    function test_mintAndSchedulePaysNativeEmissionsFromSchedulerBalance() public {
        uint128 expectedAmount = SCHEDULE_DURATION;
        vm.deal(address(this), expectedAmount);
        (bool success,) = address(scheduler).call{value: expectedAmount}("");
        assertTrue(success);

        uint128 amount = scheduler.mintAndSchedule();

        (uint128 saved,) = core.savedBalances(
            address(ve), NATIVE_TOKEN_ADDRESS, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
        assertEq(scheduler.stakeToken(), NATIVE_TOKEN_ADDRESS);
        assertEq(amount, expectedAmount);
        assertEq(address(scheduler).balance, 0);
        assertEq(saved, expectedAmount);
    }

    function test_mintAndScheduleRevertsAtomicallyWhenNativeBalanceIsInsufficient() public {
        uint256 funding = SCHEDULE_DURATION - 1;
        vm.deal(address(scheduler), funding);
        uint64 initialPolicyCursor = scheduler.lastScheduledTime();
        uint64 initialEmissionEnd = scheduler.emissionEnd();

        vm.expectRevert();
        scheduler.mintAndSchedule();

        (uint128 saved,) = core.savedBalances(
            address(ve), NATIVE_TOKEN_ADDRESS, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
        assertEq(scheduler.lastScheduledTime(), initialPolicyCursor);
        assertEq(scheduler.emissionEnd(), initialEmissionEnd);
        assertEq(address(scheduler).balance, funding);
        assertEq(saved, 0);
    }
}
