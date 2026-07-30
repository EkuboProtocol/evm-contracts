// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {FullTest} from "./FullTest.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IVe33} from "../src/interfaces/extensions/IVe33.sol";
import {isTimeValid, nextValidTime} from "../src/math/time.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {ScheduledVe33EmissionRateConfig} from "../src/types/scheduledVe33EmissionRateConfig.sol";
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";

/// @notice Stateful fuzz handler for Ve33EmissionRateScheduler.
/// @dev Ve33 and its periphery only vary the external emission environment. Assertions are deliberately limited to
///      state, accounting, configuration, funding, and atomicity owned by the scheduler.
contract Ve33EmissionRateSchedulerInvariantHandler is StdUtils {
    uint256 private constant MAX_CONFIGS = 12;
    uint256 private constant MAX_CONFIG_DELAY = 120 days;
    uint256 private constant MAX_TIME_ADVANCE = 45 days;
    uint160 private constant MAX_ROUTINE_RATE = uint160(uint256(1e20) << 32);

    struct PokeExpectation {
        ScheduledVe33EmissionRateConfig finalConfig;
        uint64 lastScheduledTime;
        uint64 activatedAtStart;
        uint64 activatedAtEnd;
        uint32 rateRemainder;
        uint256 policyAmount;
        bool overflows;
    }

    Ve33EmissionRateScheduler private immutable scheduler;
    Ve33Periphery private immutable periphery;
    MintableERC20 private immutable stakeToken;
    Vm private immutable vm;
    bool private immutable isNative;

    uint64 private observedLastScheduledTime;
    uint64 private observedEmissionEnd;
    uint256 private expectedSchedulerBalance;

    error UnexpectedError(bytes data);
    error UnexpectedCallResult(bool expectedSuccess, bool actualSuccess);
    /// @dev Codes: 1 storage, 2 balance, 3 config result, 4 accounting cursor, 5 deletion, 6 payment,
    ///      7 policy result, 8 monotonicity, 9 execution timestamp, 10 config list, 11 remainder, 12 transfer.
    error InvariantViolation(uint256 code);

    constructor(Ve33EmissionRateScheduler _scheduler, Ve33Periphery _periphery, MintableERC20 _stakeToken, Vm _vm) {
        scheduler = _scheduler;
        periphery = _periphery;
        stakeToken = _stakeToken;
        vm = _vm;
        isNative = address(_stakeToken) == NATIVE_TOKEN_ADDRESS;

        if (!isNative) _stakeToken.approve(address(_periphery), type(uint256).max);

        observedLastScheduledTime = _scheduler.lastScheduledTime();
        observedEmissionEnd = _scheduler.emissionEnd();
        expectedSchedulerBalance = _assetBalance(address(_scheduler));
    }

    receive() external payable {}

    function advanceTime(uint32 seed) external {
        bytes32 schedulerStateBefore = _schedulerStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));
        uint256 by;
        uint8 mode = uint8(seed);
        if (mode % 8 == 0) {
            by = 0;
        } else if (mode % 8 == 1) {
            by = 1;
        } else if (mode % 8 == 2) {
            by = 255;
        } else if (mode % 8 == 3) {
            by = 256;
        } else if (mode % 8 == 4) {
            by = 1 weeks;
        } else {
            by = _bound(uint256(seed), 0, MAX_TIME_ADVANCE);
        }

        vm.warp(vm.getBlockTimestamp() + by);
        _check(_schedulerStateHash() == schedulerStateBefore, 1);
        _check(_assetBalance(address(scheduler)) == schedulerBalanceBefore, 2);
        _afterAction();
    }

    function setConfig(uint160 rateSeed, uint32 durationSeed) external {
        uint160 rate = _rate(rateSeed);
        uint32 duration = _duration(durationSeed);
        bool expectedSuccess = _canSetConfig(rate, duration);
        bytes32 stateBefore = _schedulerStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));
        uint64 nextConfigTimeBefore = scheduler.config().nextConfigTime();

        bool success;
        try scheduler.setConfig(rate, duration) {
            success = true;
        } catch (bytes memory reason) {
            if (expectedSuccess || !_isConfigurationError(_selector(reason))) revert UnexpectedError(reason);
        }

        if (success != expectedSuccess) revert UnexpectedCallResult(expectedSuccess, success);
        if (success) {
            Ve33EmissionRateConfig rateConfig = scheduler.config().emissionRateConfig();
            _check(rateConfig.minEmissionsRate() == rate, 3);
            _check(rateConfig.scheduleDuration() == duration, 3);
            _check(scheduler.config().nextConfigTime() == nextConfigTimeBefore, 3);
            _check(scheduler.lastScheduledTime() == vm.getBlockTimestamp(), 3);
            _check(scheduler.emissionEnd() == vm.getBlockTimestamp(), 3);
            _check(scheduler.rateRemainder() == 0, 3);
        } else {
            _check(_schedulerStateHash() == stateBefore, 1);
        }
        _check(_assetBalance(address(scheduler)) == schedulerBalanceBefore, 2);
        _afterAction();
    }

    function scheduleConfig(uint64 timeSeed, uint160 rateSeed, uint32 durationSeed, uint8 behavior) external {
        (, uint64[] memory times) = scheduler.getConfigState();
        if (times.length >= MAX_CONFIGS && behavior % 5 == 0) {
            _afterAction();
            return;
        }

        uint64 startTime = _configTime(timeSeed, times, behavior);
        uint160 rate = _rate(rateSeed);
        uint32 duration = _duration(durationSeed);
        uint64 correctPreviousTime = _previousConfigTime(startTime, times);
        uint64 previousConfigTime =
            behavior % 5 == 4 ? _incorrectPreviousTime(startTime, correctPreviousTime, times) : correctPreviousTime;

        bool expectedSuccess = _canScheduleConfig(startTime, duration, previousConfigTime);
        bytes32 stateBefore = _schedulerStateHash();
        bytes32 accountingStateBefore = _accountingStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));

        bool success;
        try scheduler.scheduleConfig(startTime, rate, duration, previousConfigTime) {
            success = true;
        } catch (bytes memory reason) {
            if (expectedSuccess || !_isConfigurationError(_selector(reason))) revert UnexpectedError(reason);
        }

        if (success != expectedSuccess) revert UnexpectedCallResult(expectedSuccess, success);
        if (success) {
            ScheduledVe33EmissionRateConfig scheduledConfig = scheduler.scheduledConfigs(startTime);
            _check(scheduledConfig.emissionRateConfig().minEmissionsRate() == rate, 3);
            _check(scheduledConfig.emissionRateConfig().scheduleDuration() == duration, 3);
        } else {
            _check(_schedulerStateHash() == stateBefore, 1);
        }
        _check(_accountingStateHash() == accountingStateBefore, 4);
        _check(_assetBalance(address(scheduler)) == schedulerBalanceBefore, 2);
        _afterAction();
    }

    function cancelConfig(uint64 timeSeed, uint8 behavior) external {
        (, uint64[] memory times) = scheduler.getConfigState();
        (uint64 startTime, uint64 previousConfigTime) = _cancellationInputs(timeSeed, times, behavior);
        bool expectedSuccess = _canCancelConfig(startTime, previousConfigTime);
        bytes32 stateBefore = _schedulerStateHash();
        bytes32 accountingStateBefore = _accountingStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));

        bool success;
        try scheduler.cancelConfig(startTime, previousConfigTime) {
            success = true;
        } catch (bytes memory reason) {
            if (expectedSuccess || !_isConfigurationError(_selector(reason))) revert UnexpectedError(reason);
        }

        if (success != expectedSuccess) revert UnexpectedCallResult(expectedSuccess, success);
        if (success) {
            _check(ScheduledVe33EmissionRateConfig.unwrap(scheduler.scheduledConfigs(startTime)) == bytes32(0), 5);
        } else {
            _check(_schedulerStateHash() == stateBefore, 1);
        }
        _check(_accountingStateHash() == accountingStateBefore, 4);
        _check(_assetBalance(address(scheduler)) == schedulerBalanceBefore, 2);
        _afterAction();
    }

    function scheduleEmissions(uint8 numberOfCalls) external {
        numberOfCalls = uint8(_bound(numberOfCalls, 1, 4));
        for (uint256 i; i < numberOfCalls; i++) {
            _scheduleEmissionsOnce();
        }
        _afterAction();
    }

    function multicallScheduleEmissions(uint8 numberOfCalls) external {
        numberOfCalls = uint8(_bound(numberOfCalls, 1, 4));
        bytes[] memory calls = new bytes[](numberOfCalls);
        for (uint256 i; i < numberOfCalls; i++) {
            calls[i] = abi.encodeCall(scheduler.scheduleEmissions, ());
        }

        bytes32 stateBefore = _schedulerStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));

        bool success;
        bytes[] memory results;
        try scheduler.multicall(calls) returns (bytes[] memory callResults) {
            success = true;
            results = callResults;
        } catch (bytes memory reason) {
            if (!_isSchedulingError(_selector(reason))) revert UnexpectedError(reason);
        }

        if (success) {
            uint256 totalPaid;
            for (uint256 i; i < results.length; i++) {
                totalPaid += abi.decode(results[i], (uint128));
            }
            _assertPaymentDelta(schedulerBalanceBefore, totalPaid);
            expectedSchedulerBalance -= totalPaid;
        } else {
            _check(_schedulerStateHash() == stateBefore, 1);
            _assertPaymentDelta(schedulerBalanceBefore, 0);
        }

        _afterAction();
    }

    function moveFunding(uint128 amountSeed, bool fundScheduler) external {
        bytes32 schedulerStateBefore = _schedulerStateHash();
        if (fundScheduler) {
            uint256 available = _assetBalance(address(this));
            uint256 amount = _bound(uint256(amountSeed), 0, available);
            if (isNative) {
                (bool success,) = address(scheduler).call{value: amount}("");
                _check(success, 12);
            } else {
                _check(stakeToken.transfer(address(scheduler), amount), 12);
            }
            expectedSchedulerBalance += amount;
        } else {
            uint256 available = _assetBalance(address(scheduler));
            uint256 amount = _bound(uint256(amountSeed), 0, available);
            if (isNative) {
                scheduler.call(address(this), amount, "");
            } else {
                scheduler.call(
                    address(stakeToken), 0, abi.encodeWithSelector(stakeToken.transfer.selector, address(this), amount)
                );
            }
            expectedSchedulerBalance -= amount;
        }

        _check(_schedulerStateHash() == schedulerStateBefore, 1);
        _afterAction();
    }

    function scheduleExternalEmissions(uint160 rateSeed, uint32 endSeed, uint32 startSeed, bool futureStart) external {
        uint256 nowTime = vm.getBlockTimestamp();
        uint256 endOffset = _bound(uint256(endSeed), 256, 30 days);
        uint64 endTime = uint64(nextValidTime(nowTime, nowTime + endOffset));
        uint64 startTime;
        if (futureStart) {
            uint256 startOffset = _bound(uint256(startSeed), 0, endOffset / 2);
            startTime = uint64(nextValidTime(nowTime, nowTime + startOffset));
            if (startTime >= endTime) startTime = 0;
        }

        uint160 rate = _externalRate(rateSeed);
        uint256 realStartTime = startTime > nowTime ? startTime : nowTime;
        uint128 expectedAmount = uint128((((uint256(endTime) - realStartTime) * rate) + type(uint32).max) >> 32);
        if (expectedAmount > _assetBalance(address(this))) {
            _afterAction();
            return;
        }

        bytes32 schedulerStateBefore = _schedulerStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));
        bytes memory callData = abi.encodeCall(periphery.scheduleEmissions, (startTime, endTime, rate));
        (bool success, bytes memory result) = address(periphery).call{value: isNative ? expectedAmount : 0}(callData);

        if (!success) {
            if (!_isExternalSchedulingError(_selector(result))) revert UnexpectedError(result);
        }
        _check(_schedulerStateHash() == schedulerStateBefore, 1);
        _check(_assetBalance(address(scheduler)) == schedulerBalanceBefore, 2);

        _afterAction();
    }

    function checkSchedulerState() external view {
        _check(scheduler.lastScheduledTime() == observedLastScheduledTime, 7);
        _check(scheduler.emissionEnd() == observedEmissionEnd, 7);
        _check(_assetBalance(address(scheduler)) == expectedSchedulerBalance, 2);
        _assertConfigList();
    }

    function _scheduleEmissionsOnce() private {
        PokeExpectation memory expected = _pokeExpectation();
        bytes32 stateBefore = _schedulerStateHash();
        uint256 schedulerBalanceBefore = _assetBalance(address(scheduler));

        bool success;
        uint128 amount;
        try scheduler.scheduleEmissions() returns (uint128 paid) {
            success = true;
            amount = paid;
        } catch (bytes memory reason) {
            bytes4 selector = _selector(reason);
            if (expected.overflows) {
                if (selector != Ve33EmissionRateScheduler.EmissionAmountOverflow.selector) {
                    revert UnexpectedError(reason);
                }
            } else if (
                selector == Ve33EmissionRateScheduler.EmissionAmountOverflow.selector || !_isSchedulingError(selector)
            ) {
                revert UnexpectedError(reason);
            }
        }

        if (success) {
            _check(!expected.overflows, 7);
            _check(scheduler.lastScheduledTime() == expected.lastScheduledTime, 7);
            _check(scheduler.rateRemainder() == expected.rateRemainder, 7);
            _check(
                ScheduledVe33EmissionRateConfig.unwrap(scheduler.config())
                    == ScheduledVe33EmissionRateConfig.unwrap(expected.finalConfig),
                7
            );
            if (expected.activatedAtStart != 0) _assertConfigDeleted(expected.activatedAtStart);
            if (expected.activatedAtEnd != 0) _assertConfigDeleted(expected.activatedAtEnd);
            if (expected.policyAmount == 0) _check(amount == 0, 7);
            _assertPaymentDelta(schedulerBalanceBefore, amount);
            expectedSchedulerBalance -= amount;
        } else {
            _check(_schedulerStateHash() == stateBefore, 1);
            _assertPaymentDelta(schedulerBalanceBefore, 0);
        }
    }

    function _pokeExpectation() private view returns (PokeExpectation memory expected) {
        ScheduledVe33EmissionRateConfig config_ = scheduler.config();
        uint64 lastScheduledTime_ = scheduler.lastScheduledTime();
        uint32 remainder = scheduler.rateRemainder();
        uint64 nextConfigTime_ = config_.nextConfigTime();

        if (nextConfigTime_ != 0 && nextConfigTime_ == lastScheduledTime_) {
            expected.activatedAtStart = nextConfigTime_;
            config_ = scheduler.scheduledConfigs(nextConfigTime_);
            nextConfigTime_ = config_.nextConfigTime();
            remainder = 0;
        }

        expected.finalConfig = config_;
        expected.lastScheduledTime = lastScheduledTime_;
        expected.rateRemainder = remainder;

        Ve33EmissionRateConfig rateConfig = config_.emissionRateConfig();
        uint32 duration = rateConfig.scheduleDuration();
        if (duration == 0) return expected;

        uint64 horizon = uint64(vm.getBlockTimestamp()) + duration;
        if (nextConfigTime_ != 0 && nextConfigTime_ < horizon) horizon = nextConfigTime_;
        if (horizon <= lastScheduledTime_) return expected;

        uint256 accruedQ32 = uint256(horizon - lastScheduledTime_) * rateConfig.minEmissionsRate() + uint256(remainder);
        expected.policyAmount = accruedQ32 >> 32;
        if (expected.policyAmount > type(uint128).max) {
            expected.overflows = true;
            return expected;
        }

        expected.lastScheduledTime = horizon;
        expected.rateRemainder = uint32(accruedQ32);
        if (nextConfigTime_ != 0 && horizon == nextConfigTime_) {
            expected.activatedAtEnd = nextConfigTime_;
            expected.finalConfig = scheduler.scheduledConfigs(nextConfigTime_);
            expected.rateRemainder = 0;
        }
    }

    function _assertPaymentDelta(uint256 schedulerBalanceBefore, uint256 amount) private view {
        _check(_assetBalance(address(scheduler)) + amount == schedulerBalanceBefore, 6);
    }

    function _afterAction() private {
        uint64 lastScheduledTime_ = scheduler.lastScheduledTime();
        uint64 emissionEnd_ = scheduler.emissionEnd();

        _check(lastScheduledTime_ >= observedLastScheduledTime, 8);
        _check(emissionEnd_ >= observedEmissionEnd, 8);

        observedLastScheduledTime = lastScheduledTime_;
        observedEmissionEnd = emissionEnd_;

        if (emissionEnd_ > vm.getBlockTimestamp()) {
            _check(isTimeValid(vm.getBlockTimestamp(), emissionEnd_), 9);
        }

        _assertConfigList();
        _check(_assetBalance(address(scheduler)) == expectedSchedulerBalance, 2);
    }

    function _assertConfigList() private view {
        (ScheduledVe33EmissionRateConfig currentConfig, uint64[] memory times) = scheduler.getConfigState();
        _check(
            ScheduledVe33EmissionRateConfig.unwrap(currentConfig)
                == ScheduledVe33EmissionRateConfig.unwrap(scheduler.config()),
            10
        );
        _check(times.length <= MAX_CONFIGS, 10);

        Ve33EmissionRateConfig activeRateConfig = currentConfig.emissionRateConfig();
        if (activeRateConfig.minEmissionsRate() != 0) {
            _check(activeRateConfig.scheduleDuration() != 0, 10);
        } else {
            _check(scheduler.rateRemainder() == 0, 11);
        }

        uint64 expectedTime = currentConfig.nextConfigTime();
        uint64 previousTime;
        for (uint256 i; i < times.length; i++) {
            uint64 time = times[i];
            _check(time == expectedTime, 10);
            _check(time > previousTime, 10);
            _check(time > scheduler.lastScheduledTime(), 10);

            ScheduledVe33EmissionRateConfig scheduledConfig = scheduler.scheduledConfigs(time);
            _check(scheduledConfig.emissionRateConfig().scheduleDuration() != 0, 10);
            expectedTime = scheduledConfig.nextConfigTime();
            previousTime = time;
        }
        _check(expectedTime == 0, 10);
    }

    function _assertConfigDeleted(uint64 startTime) private view {
        _check(ScheduledVe33EmissionRateConfig.unwrap(scheduler.scheduledConfigs(startTime)) == bytes32(0), 5);
    }

    function _canSetConfig(uint160 rate, uint32 duration) private view returns (bool) {
        if (rate != 0 && duration == 0) return false;
        uint64 nextConfigTime_ = scheduler.config().nextConfigTime();
        if (nextConfigTime_ != 0 && nextConfigTime_ <= vm.getBlockTimestamp()) return false;
        uint64 accountedUntil = scheduler.lastScheduledTime() > scheduler.emissionEnd()
            ? scheduler.lastScheduledTime()
            : scheduler.emissionEnd();
        return accountedUntil <= vm.getBlockTimestamp();
    }

    function _canScheduleConfig(uint64 startTime, uint32 duration, uint64 previousConfigTime)
        private
        view
        returns (bool)
    {
        if (duration == 0) return false;
        if (startTime <= vm.getBlockTimestamp() || startTime <= scheduler.lastScheduledTime()) return false;
        if (ScheduledVe33EmissionRateConfig.unwrap(scheduler.scheduledConfigs(startTime)) != bytes32(0)) return false;

        uint64 followingConfigTime;
        if (previousConfigTime == 0) {
            followingConfigTime = scheduler.config().nextConfigTime();
            return followingConfigTime == 0 || startTime < followingConfigTime;
        }

        ScheduledVe33EmissionRateConfig previousConfig = scheduler.scheduledConfigs(previousConfigTime);
        if (previousConfig.emissionRateConfig().scheduleDuration() == 0 || previousConfigTime >= startTime) {
            return false;
        }
        followingConfigTime = previousConfig.nextConfigTime();
        return followingConfigTime == 0 || startTime < followingConfigTime;
    }

    function _canCancelConfig(uint64 startTime, uint64 previousConfigTime) private view returns (bool) {
        if (startTime <= vm.getBlockTimestamp() || startTime <= scheduler.lastScheduledTime()) return false;
        ScheduledVe33EmissionRateConfig scheduledConfig = scheduler.scheduledConfigs(startTime);
        if (scheduledConfig.emissionRateConfig().scheduleDuration() == 0) return false;

        if (previousConfigTime == 0) return scheduler.config().nextConfigTime() == startTime;
        ScheduledVe33EmissionRateConfig previousConfig = scheduler.scheduledConfigs(previousConfigTime);
        return
            previousConfig.emissionRateConfig().scheduleDuration() != 0 && previousConfig.nextConfigTime() == startTime;
    }

    function _configTime(uint64 seed, uint64[] memory times, uint8 behavior) private view returns (uint64 time) {
        uint8 mode = behavior % 5;
        if (mode == 1 && times.length != 0) return times[uint256(seed) % times.length];
        if (mode == 2) {
            uint64 nowTime = uint64(vm.getBlockTimestamp());
            return nowTime - uint64(_bound(uint256(seed), 0, nowTime));
        }
        if (mode == 3) return scheduler.lastScheduledTime();

        uint64 base = scheduler.lastScheduledTime() > vm.getBlockTimestamp()
            ? scheduler.lastScheduledTime()
            : uint64(vm.getBlockTimestamp());
        time = base + uint64(1 + (uint256(seed) % MAX_CONFIG_DELAY));
        while (ScheduledVe33EmissionRateConfig.unwrap(scheduler.scheduledConfigs(time)) != bytes32(0)) {
            time++;
        }
    }

    function _previousConfigTime(uint64 startTime, uint64[] memory times) private pure returns (uint64 previousTime) {
        for (uint256 i; i < times.length && times[i] < startTime; i++) {
            previousTime = times[i];
        }
    }

    function _incorrectPreviousTime(uint64 startTime, uint64 correctPreviousTime, uint64[] memory times)
        private
        pure
        returns (uint64)
    {
        if (correctPreviousTime != 0) return 0;
        if (times.length != 0) return times[times.length - 1];
        return startTime - 1;
    }

    function _cancellationInputs(uint64 seed, uint64[] memory times, uint8 behavior)
        private
        view
        returns (uint64 startTime, uint64 previousConfigTime)
    {
        uint8 mode = behavior % 4;
        if (times.length != 0 && mode < 3) {
            uint256 index = uint256(seed) % times.length;
            startTime = times[index];
            previousConfigTime = index == 0 ? 0 : times[index - 1];
            if (mode == 1) {
                previousConfigTime = _incorrectPreviousTime(startTime, previousConfigTime, times);
            }
            return (startTime, previousConfigTime);
        }

        uint64 base = scheduler.lastScheduledTime() > vm.getBlockTimestamp()
            ? scheduler.lastScheduledTime()
            : uint64(vm.getBlockTimestamp());
        startTime = base + uint64(1 + (uint256(seed) % MAX_CONFIG_DELAY));
        while (ScheduledVe33EmissionRateConfig.unwrap(scheduler.scheduledConfigs(startTime)) != bytes32(0)) {
            startTime++;
        }
    }

    function _rate(uint160 seed) private pure returns (uint160) {
        uint8 mode = uint8(seed) % 8;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return uint160(1 << 32);
        if (mode == 3) return uint160(uint256(1e18) << 32);
        if (mode == 4) return type(uint160).max;
        return uint160(uint256(seed) % (uint256(MAX_ROUTINE_RATE) + 1));
    }

    function _externalRate(uint160 seed) private pure returns (uint160) {
        uint8 mode = uint8(seed) % 4;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return uint160(1 << 32);
        return uint160(uint256(seed) % (uint256(MAX_ROUTINE_RATE) + 1));
    }

    function _duration(uint32 seed) private pure returns (uint32) {
        uint8 mode = uint8(seed) % 8;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return 255;
        if (mode == 3) return 256;
        if (mode == 4) return 4095;
        if (mode == 5) return 1 weeks;
        if (mode == 6) return type(uint32).max;
        return uint32(1 + (uint256(seed) % 30 days));
    }

    function _schedulerStateHash() private view returns (bytes32 hash) {
        (ScheduledVe33EmissionRateConfig currentConfig, uint64[] memory times) = scheduler.getConfigState();
        hash = keccak256(
            abi.encode(
                currentConfig, scheduler.lastScheduledTime(), scheduler.emissionEnd(), scheduler.rateRemainder(), times
            )
        );
        for (uint256 i; i < times.length; i++) {
            hash = keccak256(abi.encode(hash, times[i], scheduler.scheduledConfigs(times[i])));
        }
    }

    function _accountingStateHash() private view returns (bytes32) {
        return keccak256(abi.encode(scheduler.lastScheduledTime(), scheduler.emissionEnd(), scheduler.rateRemainder()));
    }

    function _assetBalance(address account) private view returns (uint256) {
        return isNative ? account.balance : stakeToken.balanceOf(account);
    }

    function _isConfigurationError(bytes4 selector) private pure returns (bool) {
        return selector == Ve33EmissionRateScheduler.InvalidScheduleDuration.selector
            || selector == Ve33EmissionRateScheduler.InvalidConfigTime.selector
            || selector == Ve33EmissionRateScheduler.InvalidPreviousConfigTime.selector
            || selector == Ve33EmissionRateScheduler.ConfigAlreadyScheduled.selector
            || selector == Ve33EmissionRateScheduler.ConfigNotScheduled.selector
            || selector == Ve33EmissionRateScheduler.EmissionsAlreadyScheduled.selector
            || selector == Ve33EmissionRateScheduler.ConfigUpdateDue.selector;
    }

    function _isSchedulingError(bytes4 selector) private pure returns (bool) {
        return selector == Ve33EmissionRateScheduler.EmissionAmountOverflow.selector
            || selector == Ve33EmissionRateScheduler.NoValidEmissionEnd.selector
            || selector == SafeTransferLib.TransferFailed.selector
            || selector == SafeTransferLib.ETHTransferFailed.selector || selector == ICore.SavedBalanceOverflow.selector
            || selector == IVe33.EmissionFundingOverflow.selector || selector == IVe33.MaxRateDeltaPerTime.selector;
    }

    function _isExternalSchedulingError(bytes4 selector) private pure returns (bool) {
        return selector == SafeTransferLib.TransferFromFailed.selector
            || selector == SafeTransferLib.ETHTransferFailed.selector || selector == ICore.SavedBalanceOverflow.selector
            || selector == IVe33.EmissionFundingOverflow.selector || selector == IVe33.MaxRateDeltaPerTime.selector;
    }

    function _check(bool condition, uint256 code) private pure {
        if (!condition) revert InvariantViolation(code);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
        }
    }
}

abstract contract Ve33EmissionRateSchedulerInvariantBase is FullTest {
    uint256 internal constant TOTAL_ASSET_AMOUNT = type(uint128).max;
    uint256 internal constant SCHEDULER_FUNDING = type(uint128).max / 2;
    uint256 internal constant INITIAL_TIME = type(uint32).max - 10 days;

    Ve33EmissionRateSchedulerInvariantHandler internal handler;

    function _initializeInvariant(MintableERC20 stakeToken) internal {
        vm.warp(INITIAL_TIME);

        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        Ve33 ve33 = Ve33(payable(deployAddress));
        Ve33EmissionRateScheduler scheduler = new Ve33EmissionRateScheduler(owner, core, ve33);
        Ve33Periphery periphery = new Ve33Periphery(core, ve33);

        vm.prank(owner);
        scheduler.setConfig(0, 1 weeks);

        if (address(stakeToken) == NATIVE_TOKEN_ADDRESS) {
            vm.deal(address(scheduler), SCHEDULER_FUNDING);
        } else {
            stakeToken.mint(address(scheduler), uint128(SCHEDULER_FUNDING));
        }

        handler = new Ve33EmissionRateSchedulerInvariantHandler(scheduler, periphery, stakeToken, vm);
        vm.prank(owner);
        scheduler.transferOwnership(address(handler));

        if (address(stakeToken) == NATIVE_TOKEN_ADDRESS) {
            vm.deal(address(handler), TOTAL_ASSET_AMOUNT - SCHEDULER_FUNDING);
        } else {
            stakeToken.mint(address(handler), uint128(TOTAL_ASSET_AMOUNT - SCHEDULER_FUNDING));
        }

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.advanceTime.selector;
        selectors[1] = handler.setConfig.selector;
        selectors[2] = handler.scheduleConfig.selector;
        selectors[3] = handler.cancelConfig.selector;
        selectors[4] = handler.scheduleEmissions.selector;
        selectors[5] = handler.multicallScheduleEmissions.selector;
        selectors[6] = handler.moveFunding.selector;
        selectors[7] = handler.scheduleExternalEmissions.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_schedulerStateRemainsConsistent() public view {
        handler.checkSchedulerState();
    }
}

contract Ve33EmissionRateSchedulerERC20InvariantTest is Ve33EmissionRateSchedulerInvariantBase {
    function setUp() public override {
        super.setUp();
        _initializeInvariant(new MintableERC20(address(this), "Invariant Token", "INV", 18));
    }
}

contract Ve33EmissionRateSchedulerNativeInvariantTest is Ve33EmissionRateSchedulerInvariantBase {
    function setUp() public override {
        super.setUp();
        _initializeInvariant(MintableERC20(NATIVE_TOKEN_ADDRESS));
    }
}
