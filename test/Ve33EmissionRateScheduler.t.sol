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
import {nextValidTime} from "../src/math/time.sol";
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

    MintableERC20 internal stakeToken;
    Ve33 internal ve;
    Ve33EmissionRateScheduler internal scheduler;

    function setUp() public override {
        super.setUp();

        stakeToken = new MintableERC20(address(this), "Mintable TestToken", "mTT");
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));

        scheduler = new Ve33EmissionRateScheduler(owner, core, ve);
        stakeToken.transferOwnership(address(scheduler));
    }

    function test_constructorReadsTokenFromVe33() public view {
        assertEq(address(scheduler.token()), address(stakeToken));
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
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        Ve33EmissionRateConfig config = scheduler.config();
        assertEq(config.targetRate(), TARGET_RATE);
        assertEq(config.scheduleDuration(), SCHEDULE_DURATION);
    }

    function test_mintAndScheduleReturnsZeroWhenTargetRateIsZero() public {
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(ve.emissionRate(), 0);
    }

    function test_lockCallbackFailsIfNotCore() public {
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        scheduler.locked_6416899205(0);
    }

    function test_mintAndScheduleMintsAndSchedulesShortfall() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 expectedEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 expectedAmount = _scheduleAmount(TARGET_RATE, expectedEndTime);

        uint128 amount = scheduler.mintAndSchedule();

        assertEq(amount, expectedAmount);
        assertEq(stakeToken.totalSupply(), expectedAmount);
        assertEq(stakeToken.balanceOf(address(core)), expectedAmount);
        assertEq(_rewardSavedBalance(), expectedAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
        assertEq(ve.emissionRateDeltaAtTime(expectedEndTime), -int256(uint256(TARGET_RATE)));
    }

    function test_mintAndScheduleReturnsZeroWhenCurrentRateAlreadyAtTarget() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint128 firstAmount = scheduler.mintAndSchedule();
        assertGt(firstAmount, 0);

        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, 0);
        assertEq(stakeToken.totalSupply(), firstAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function test_mintAndScheduleTopsUpOnlyRateShortfall() public {
        uint160 initialTarget = TARGET_RATE / 4;

        vm.startPrank(owner);
        scheduler.setConfig(initialTarget, SCHEDULE_DURATION);
        vm.stopPrank();
        uint128 firstAmount = scheduler.mintAndSchedule();

        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 expectedEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint160 shortfall;
        unchecked {
            shortfall = TARGET_RATE - initialTarget;
        }
        uint128 expectedTopUp = _scheduleAmount(shortfall, expectedEndTime);

        uint128 topUp = scheduler.mintAndSchedule();

        assertEq(topUp, expectedTopUp);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + topUp);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function test_mintAndScheduleAccruesExpiredScheduleBeforeCheckingTarget() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 endTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();

        vm.warp(endTime);

        uint64 nextEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 expectedAmount = _scheduleAmount(TARGET_RATE, nextEndTime);
        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, expectedAmount);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + secondAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function _expectedEndTime(uint32 scheduleDuration) internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + uint256(scheduleDuration) - 1));
    }

    function _scheduleAmount(uint160 rewardRate, uint64 endTime) internal view returns (uint128) {
        return uint128((((endTime - vm.getBlockTimestamp()) * uint256(rewardRate)) + type(uint32).max) >> 32);
    }

    function _scheduledAmountForFutureInterval(uint160 rewardRate, uint64 startTime, uint64 endTime)
        internal
        pure
        returns (uint128)
    {
        return uint128((((endTime - startTime) * uint256(rewardRate)) + type(uint32).max) >> 32);
    }

    function _rewardSavedBalance() internal view returns (uint128 saved) {
        (saved,) = core.savedBalances(
            address(ve), address(stakeToken), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
    }

    // ─── BaseOwnableExecutor.call surface ────────────────────────────────────

    function test_call_forwardsArbitraryCallFromOwner() public {
        vm.prank(owner);
        bytes memory result = scheduler.call(address(stakeToken), 0, abi.encodeWithSignature("owner()"));
        assertEq(abi.decode(result, (address)), address(scheduler));
    }

    function test_call_failsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.call(address(0), 0, "");
    }

    function test_call_bubblesRevert() public {
        SchedulerCallRevertTarget target = new SchedulerCallRevertTarget();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SchedulerCallRevertTarget.SchedulerTestError.selector, 42));
        scheduler.call(address(target), 0, abi.encodeCall(SchedulerCallRevertTarget.fail, (42)));
    }

    // ─── nextEmissionRateChangeTime helper ───────────────────────────────────

    function test_nextEmissionRateChangeTime_returnsZeroWhenNoSchedule() public view {
        (uint64 time, int256 delta) = ve.nextEmissionRateChangeTime(block.timestamp);
        assertEq(time, 0);
        assertEq(delta, 0);
    }

    function test_nextEmissionRateChangeTime_returnsNextScheduledChange() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 expectedEnd = _expectedEndTime(SCHEDULE_DURATION);
        scheduler.mintAndSchedule();

        (uint64 time, int256 delta) = ve.nextEmissionRateChangeTime(block.timestamp);
        assertEq(time, expectedEnd);
        assertEq(delta, -int256(uint256(TARGET_RATE)));
    }

    // ─── Forward-looking top-up tests ────────────────────────────────────────

    function test_mintAndSchedule_topsUpWhenFutureDeltaDropsBelowTarget() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        // First call: schedule [now, H1] at TARGET_RATE
        uint64 h1 = _expectedEndTime(SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();
        assertGt(firstAmount, 0);
        assertEq(ve.emissionRate(), TARGET_RATE);
        assertEq(ve.emissionRateDeltaAtTime(h1), -int256(uint256(TARGET_RATE)));

        // Switch to a longer duration; new horizon H2 > H1
        uint32 longDuration = SCHEDULE_DURATION * 2;
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, longDuration);
        uint64 h2 = _expectedEndTime(longDuration);
        assertGt(h2, h1);

        // Second call: current rate == TARGET_RATE (no immediate shortfall),
        // but at H1 the delta -TARGET_RATE drops rate to 0 < TARGET_RATE.
        // The scheduler should top up [H1, H2] at TARGET_RATE.
        uint128 expectedTopUp = _scheduledAmountForFutureInterval(TARGET_RATE, h1, h2);
        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, expectedTopUp);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + secondAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
        // Deltas at H1 cancel out (first schedule end + second schedule start).
        assertEq(ve.emissionRateDeltaAtTime(h1), 0);
        // Delta at H2 is the combined end of both schedules.
        assertEq(ve.emissionRateDeltaAtTime(h2), -int256(uint256(TARGET_RATE)));
    }

    function test_mintAndSchedule_noDoubleSchedulingAfterForwardTopup() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);
        scheduler.mintAndSchedule(); // [now, H1] at TARGET_RATE

        uint32 longDuration = SCHEDULE_DURATION * 2;
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, longDuration);
        uint128 topUpAmount = scheduler.mintAndSchedule(); // [H1, H2] at TARGET_RATE
        assertGt(topUpAmount, 0);

        uint256 totalMinted = stakeToken.totalSupply();

        // Third call: fully covered through H2, should return 0.
        uint128 thirdAmount = scheduler.mintAndSchedule();
        assertEq(thirdAmount, 0);
        assertEq(stakeToken.totalSupply(), totalMinted);
    }

    function test_mintAndSchedule_coversMultipleShortfallsInSingleCall() public {
        uint160 partialRate = TARGET_RATE / 4;
        uint32 longDuration = SCHEDULE_DURATION * 2;

        // Setup: schedule [now, H1] at partialRate (< TARGET_RATE).
        vm.prank(owner);
        scheduler.setConfig(partialRate, SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();
        assertEq(ve.emissionRate(), partialRate);

        uint64 h1 = _expectedEndTime(SCHEDULE_DURATION);
        uint64 h2 = _expectedEndTime(longDuration);
        assertGt(h2, h1);

        // Now target = TARGET_RATE with a longer horizon.
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, longDuration);

        // Interval 1 [now, H1]: rate = partialRate < TARGET_RATE → immediate shortfall.
        uint160 shortfall1;
        unchecked {
            shortfall1 = TARGET_RATE - partialRate;
        }
        uint128 immediateTopUp = _scheduleAmount(shortfall1, h1);

        // After topping up [now, H1]: combined delta at H1 = -partialRate + -(TARGET_RATE-partialRate) = -TARGET_RATE.
        // Projected rate after H1 = TARGET_RATE - TARGET_RATE = 0 < TARGET_RATE → second shortfall.
        // Interval 2 [H1, H2]: rate = 0 < TARGET_RATE → forward-looking shortfall.
        uint128 futureTopUp = _scheduledAmountForFutureInterval(TARGET_RATE, h1, h2);

        uint128 totalTopUp = scheduler.mintAndSchedule();
        assertEq(totalTopUp, immediateTopUp + futureTopUp);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + totalTopUp);
        assertEq(ve.emissionRate(), TARGET_RATE);
        // Delta at H1 cancelled out, delta at H2 holds the combined -TARGET_RATE.
        assertEq(ve.emissionRateDeltaAtTime(h1), 0);
        assertEq(ve.emissionRateDeltaAtTime(h2), -int256(uint256(TARGET_RATE)));
    }
}
