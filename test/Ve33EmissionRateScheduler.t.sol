// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";

import {FullTest} from "./FullTest.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";
import {isTimeValid, nextValidTime} from "../src/math/time.sol";
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
    uint160 private constant TARGET_RATE = uint160(uint256(1e12) << 32);
    uint160 private constant DOUBLE_TARGET_RATE = TARGET_RATE * 2;

    uint128 private constant INITIAL_DAILY_EMISSION_AMOUNT = 333_333e16;
    uint128 private constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint160 private constant INITIAL_EMISSION_RATE =
        uint160(((uint256(INITIAL_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);
    uint128 private constant ONGOING_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 private constant ONGOING_EMISSION_RATE =
        uint160(((uint256(ONGOING_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);

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
        stakeToken.transferOwnership(address(scheduler));
    }

    function test_constructorInitializesTokenAndPolicyCursor() public view {
        assertEq(address(scheduler.token()), address(stakeToken));
        assertEq(scheduler.lastScheduledTime(), block.timestamp);
        assertEq(scheduler.emissionEnd(), 0);
        assertEq(scheduler.nextConfigTime(), 0);
    }

    function test_setConfigFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);
    }

    function test_setConfigFailsWithNonzeroTargetAndZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(Ve33EmissionRateScheduler.InvalidScheduleDuration.selector);
        scheduler.setConfig(TARGET_RATE, 0);
    }

    function test_setConfigPacksTargetRateAndScheduleDuration() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);

        Ve33EmissionRateConfig config = scheduler.config();
        assertEq(config.targetRate(), TARGET_RATE);
        assertEq(config.scheduleDuration(), SCHEDULE_DURATION);
        assertEq(scheduler.lastScheduledTime(), block.timestamp);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_setConfigFailsAfterFuturePolicyWasScheduled() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);
        scheduler.mintAndSchedule();
        uint64 accountedUntil = scheduler.emissionEnd();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Ve33EmissionRateScheduler.EmissionsAlreadyScheduled.selector, accountedUntil)
        );
        scheduler.setConfig(DOUBLE_TARGET_RATE, SCHEDULE_DURATION);
    }

    function test_setConfigFailsInsteadOfSkippingDueQueuedConfig() public {
        uint64 startTime = uint64(block.timestamp + 1 days);
        _scheduleConfig(startTime, TARGET_RATE, SCHEDULE_DURATION, 0);
        vm.warp(startTime);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.ConfigUpdateDue.selector, startTime));
        scheduler.setConfig(DOUBLE_TARGET_RATE, SCHEDULE_DURATION);
    }

    function test_mintAndScheduleReturnsZeroWhenUnconfigured() public {
        uint64 initialCursor = scheduler.lastScheduledTime();

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), initialCursor);
        assertEq(stakeToken.totalSupply(), 0);
    }

    function test_zeroRateAdvancesPolicyWithoutMinting() public {
        _setConfig(0, SCHEDULE_DURATION);
        uint64 policyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint64 validEnd = _validTimeAtOrAfter(policyEnd);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), policyEnd);
        assertEq(scheduler.emissionEnd(), validEnd);
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(ve.emissionRate(), 0);
    }

    function test_lockCallbackFailsIfNotCore() public {
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        scheduler.locked_6416899205(0);
    }

    function test_mintAndScheduleMintsExactPolicyAmountIntoValidInterval() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 policyStart = uint64(block.timestamp);
        uint64 policyEnd = policyStart + SCHEDULE_DURATION;
        uint64 validEnd = _validTimeAtOrAfter(policyEnd);
        uint128 expectedAmount = uint128(uint256(SCHEDULE_DURATION) * 1e12);
        uint160 fittedRate = uint160((uint256(expectedAmount) << 32) / (validEnd - policyStart));

        uint128 amount = scheduler.mintAndSchedule();

        assertEq(amount, expectedAmount);
        assertEq(stakeToken.totalSupply(), expectedAmount);
        assertEq(stakeToken.balanceOf(address(core)), expectedAmount);
        assertEq(_rewardSavedBalance(), expectedAmount);
        assertEq(scheduler.lastScheduledTime(), policyEnd);
        assertEq(scheduler.emissionEnd(), validEnd);
        assertEq(scheduler.rateRemainder(), 0);
        assertEq(ve.emissionRate(), fittedRate);
        assertEq(ve.emissionRateDeltaAtTime(validEnd), -int256(uint256(fittedRate)));
        assertTrue(isTimeValid(policyStart, validEnd));
    }

    function test_mintAndScheduleDoesNotDoubleScheduleSamePolicyHorizon() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();

        assertGt(firstAmount, 0);
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.totalSupply(), firstAmount);
    }

    function test_mintAndScheduleAppendsAfterExistingValidEmissionEnd() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 initialTime = uint64(block.timestamp);
        uint128 firstAmount = scheduler.mintAndSchedule();
        uint64 firstPolicyEnd = initialTime + SCHEDULE_DURATION;
        uint64 firstEmissionEnd = scheduler.emissionEnd();

        vm.warp(initialTime + 3 days);

        uint64 secondPolicyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint128 expectedSecondAmount = uint128(uint256(secondPolicyEnd - firstPolicyEnd) * 1e12);
        uint64 minimumSecondEnd = secondPolicyEnd > firstEmissionEnd ? secondPolicyEnd : firstEmissionEnd + 1;
        uint64 expectedSecondEnd = _validTimeAtOrAfter(minimumSecondEnd);

        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, expectedSecondAmount);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + secondAmount);
        assertEq(scheduler.lastScheduledTime(), secondPolicyEnd);
        assertEq(scheduler.emissionEnd(), expectedSecondEnd);
        assertGt(expectedSecondEnd, firstEmissionEnd);
        assertTrue(isTimeValid(block.timestamp, expectedSecondEnd));
    }

    function test_mintAndScheduleCarriesFractionalQ32Amounts() public {
        uint160 oneThirdWeiPerSecond = uint160((uint256(1) << 32) / 3);
        _setConfig(oneThirdWeiPerSecond, 2);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.totalSupply(), 0);

        vm.warp(block.timestamp + 2);

        assertEq(scheduler.mintAndSchedule(), 1);
        assertEq(stakeToken.totalSupply(), 1);
        assertEq(scheduler.rateRemainder(), uint32(uint256(4) * oneThirdWeiPerSecond), "four seconds of Q32 remainder");
    }

    function test_mintAndScheduleRejectsPolicyAmountAboveUint128() public {
        _setConfig(type(uint160).max, type(uint32).max);

        vm.expectRevert(Ve33EmissionRateScheduler.EmissionAmountOverflow.selector);
        scheduler.mintAndSchedule();
    }

    function test_scheduleConfigFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.scheduleConfig(uint64(block.timestamp + 1 days), TARGET_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigFailsWithZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(Ve33EmissionRateScheduler.InvalidScheduleDuration.selector);
        scheduler.scheduleConfig(uint64(block.timestamp + 1 days), TARGET_RATE, 0, 0);
    }

    function test_scheduleConfigFailsAtAccountedTimestamp() public {
        uint64 accountedTime = scheduler.lastScheduledTime();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, accountedTime));
        scheduler.scheduleConfig(accountedTime, TARGET_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigInsertsWithLinkedListHints() public {
        uint64 time10 = uint64(block.timestamp + 10 days);
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);

        _scheduleConfig(time30, TARGET_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time10, TARGET_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time20, DOUBLE_TARGET_RATE, SCHEDULE_DURATION, time10);

        assertEq(scheduler.nextConfigTime(), time10);
        _assertScheduledConfig(time10, TARGET_RATE, SCHEDULE_DURATION, time20);
        _assertScheduledConfig(time20, DOUBLE_TARGET_RATE, SCHEDULE_DURATION, time30);
        _assertScheduledConfig(time30, TARGET_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigRejectsDuplicateTimestamp() public {
        uint64 startTime = uint64(block.timestamp + 10 days);
        _scheduleConfig(startTime, TARGET_RATE, SCHEDULE_DURATION, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.ConfigAlreadyScheduled.selector, startTime));
        scheduler.scheduleConfig(startTime, DOUBLE_TARGET_RATE, SCHEDULE_DURATION, 0);
    }

    function test_scheduleConfigRejectsIncorrectInsertionHint() public {
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);
        _scheduleConfig(time30, TARGET_RATE, SCHEDULE_DURATION, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidPreviousConfigTime.selector, time30));
        scheduler.scheduleConfig(time20, TARGET_RATE, SCHEDULE_DURATION, time30);
    }

    function test_scheduleConfigRejectsAlreadyAccountedFutureTime() public {
        _setConfig(0, SCHEDULE_DURATION);
        scheduler.mintAndSchedule();
        uint64 accountedTime = scheduler.lastScheduledTime();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, accountedTime));
        scheduler.scheduleConfig(accountedTime, TARGET_RATE, SCHEDULE_DURATION, 0);
    }

    function test_cancelConfigRemovesHeadAndMiddleNodes() public {
        uint64 time10 = uint64(block.timestamp + 10 days);
        uint64 time20 = uint64(block.timestamp + 20 days);
        uint64 time30 = uint64(block.timestamp + 30 days);
        _scheduleConfig(time10, TARGET_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(time20, TARGET_RATE, SCHEDULE_DURATION, time10);
        _scheduleConfig(time30, TARGET_RATE, SCHEDULE_DURATION, time20);

        vm.prank(owner);
        scheduler.cancelConfig(time20, time10);
        _assertScheduledConfig(time10, TARGET_RATE, SCHEDULE_DURATION, time30);
        _assertScheduledConfig(time20, 0, 0, 0);

        vm.prank(owner);
        scheduler.cancelConfig(time10, 0);
        assertEq(scheduler.nextConfigTime(), time30);
        _assertScheduledConfig(time10, 0, 0, 0);
    }

    function test_cancelConfigRejectsIncorrectHint() public {
        uint64 startTime = uint64(block.timestamp + 10 days);
        _scheduleConfig(startTime, TARGET_RATE, SCHEDULE_DURATION, 0);

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
        _scheduleConfig(startTime, TARGET_RATE, SCHEDULE_DURATION, 0);
        vm.warp(startTime);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ve33EmissionRateScheduler.InvalidConfigTime.selector, startTime));
        scheduler.cancelConfig(startTime, 0);
    }

    function test_arbitraryConfigStartDoesNotMintBeforePolicyStart() public {
        _setConfig(0, SCHEDULE_DURATION);
        uint64 policyStart = uint64(block.timestamp + 3 days + 123);
        assertFalse(isTimeValid(block.timestamp, policyStart));
        _scheduleConfig(policyStart, TARGET_RATE, SCHEDULE_DURATION, 0);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), policyStart);
        assertEq(scheduler.nextConfigTime(), 0);
        assertEq(scheduler.config().targetRate(), TARGET_RATE);
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(ve.emissionRate(), 0);

        uint64 fittedStart = scheduler.emissionEnd();
        assertGe(fittedStart, policyStart);
        assertTrue(isTimeValid(block.timestamp, fittedStart));

        uint64 policyEnd = uint64(block.timestamp + SCHEDULE_DURATION);
        uint128 expectedAmount = uint128(uint256(policyEnd - policyStart) * 1e12);
        assertEq(scheduler.mintAndSchedule(), expectedAmount);
        assertEq(stakeToken.totalSupply(), expectedAmount);
        assertEq(ve.emissionRate(), 0);

        int256 startRateDelta = ve.emissionRateDeltaAtTime(fittedStart);
        assertGt(startRateDelta, 0);
        vm.warp(fittedStart);
        ve.accrueEmissions();
        assertEq(ve.emissionRate(), uint160(uint256(startRateDelta)));
    }

    function test_mintAndScheduleStopsAtArbitraryNextConfigBoundary() public {
        _setConfig(TARGET_RATE, SCHEDULE_DURATION);
        uint64 policyStart = uint64(block.timestamp);
        uint64 updateTime = policyStart + 3 days + 123;
        _scheduleConfig(updateTime, DOUBLE_TARGET_RATE, SCHEDULE_DURATION, 0);

        uint128 firstExpectedAmount = uint128(uint256(updateTime - policyStart) * 1e12);
        assertEq(scheduler.mintAndSchedule(), firstExpectedAmount);
        assertEq(stakeToken.totalSupply(), firstExpectedAmount);
        assertEq(scheduler.lastScheduledTime(), updateTime);
        assertEq(scheduler.config().targetRate(), DOUBLE_TARGET_RATE);
        assertEq(scheduler.rateRemainder(), 0);

        uint64 secondPolicyEnd = policyStart + SCHEDULE_DURATION;
        uint128 secondExpectedAmount = uint128(uint256(secondPolicyEnd - updateTime) * 2e12);
        assertEq(scheduler.mintAndSchedule(), secondExpectedAmount);
        assertEq(stakeToken.totalSupply(), uint256(firstExpectedAmount) + secondExpectedAmount);
    }

    function test_configActivationResetsPriorRateRemainder() public {
        uint160 oneThirdWeiPerSecond = uint160((uint256(1) << 32) / 3);
        _setConfig(oneThirdWeiPerSecond, SCHEDULE_DURATION);
        uint64 updateTime = uint64(block.timestamp + 2);
        _scheduleConfig(updateTime, TARGET_RATE, SCHEDULE_DURATION, 0);

        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.lastScheduledTime(), updateTime);
        assertEq(scheduler.config().targetRate(), TARGET_RATE);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_weeklyPokesMintExactly333333TokensAcrossFirst100Days() public {
        _setConfig(0, SCHEDULE_DURATION);

        uint64 initialStart = uint64(block.timestamp + 1 weeks + 123);
        uint64 initialEnd = initialStart + 100 days;
        _scheduleConfig(initialStart, INITIAL_EMISSION_RATE, SCHEDULE_DURATION, 0);
        _scheduleConfig(initialEnd, ONGOING_EMISSION_RATE, SCHEDULE_DURATION, initialStart);

        assertEq((uint256(100 days) * INITIAL_EMISSION_RATE) >> 32, INITIAL_EMISSION_AMOUNT);
        assertEq(scheduler.mintAndSchedule(), 0);

        vm.warp(initialStart);
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(scheduler.config().targetRate(), INITIAL_EMISSION_RATE);

        assertGt(scheduler.mintAndSchedule(), 0);
        for (uint256 week = 1; week < 14; week++) {
            vm.warp(initialStart + week * 1 weeks);
            assertGt(scheduler.mintAndSchedule(), 0);
        }

        vm.warp(initialStart + 14 weeks);
        assertGt(scheduler.mintAndSchedule(), 0);

        assertEq(stakeToken.totalSupply(), INITIAL_EMISSION_AMOUNT);
        assertEq(_rewardSavedBalance(), INITIAL_EMISSION_AMOUNT);
        assertEq(scheduler.lastScheduledTime(), initialEnd);
        assertEq(scheduler.config().targetRate(), ONGOING_EMISSION_RATE);
        assertEq(scheduler.nextConfigTime(), 0);
        assertEq(scheduler.rateRemainder(), 0);
    }

    function test_callForwardsArbitraryCallFromOwner() public {
        vm.prank(owner);
        bytes memory result = scheduler.call(address(stakeToken), 0, abi.encodeWithSignature("owner()"));
        assertEq(abi.decode(result, (address)), address(scheduler));
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

    function _setConfig(uint160 targetRate, uint32 scheduleDuration) private {
        vm.prank(owner);
        scheduler.setConfig(targetRate, scheduleDuration);
    }

    function _scheduleConfig(uint64 startTime, uint160 targetRate, uint32 scheduleDuration, uint64 previousConfigTime)
        private
    {
        vm.prank(owner);
        scheduler.scheduleConfig(startTime, targetRate, scheduleDuration, previousConfigTime);
    }

    function _assertScheduledConfig(
        uint64 startTime,
        uint160 expectedRate,
        uint32 expectedDuration,
        uint64 expectedNextTime
    ) private view {
        (uint160 targetRate, uint32 scheduleDuration, uint64 followingConfigTime) =
            scheduler.scheduledConfigs(startTime);
        assertEq(targetRate, expectedRate);
        assertEq(scheduleDuration, expectedDuration);
        assertEq(followingConfigTime, expectedNextTime);
    }

    function _validTimeAtOrAfter(uint64 minimumTime) private view returns (uint64) {
        return uint64(nextValidTime(block.timestamp, uint256(minimumTime) - 1));
    }

    function _rewardSavedBalance() private view returns (uint128 saved) {
        (saved,) = core.savedBalances(
            address(ve), address(stakeToken), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
    }
}
