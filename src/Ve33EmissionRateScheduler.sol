// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseOwnableExecutor} from "./base/BaseOwnableExecutor.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IFlashAccountant} from "./interfaces/IFlashAccountant.sol";
import {IMintableERC20} from "./interfaces/IMintableERC20.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {nextValidTime} from "./math/time.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "./types/ve33EmissionRateConfig.sol";

/// @notice A future emission-rate configuration stored in the scheduler's time-ordered linked list.
/// @dev The fields occupy exactly one storage slot.
struct ScheduledEmissionRateConfig {
    uint160 targetRate;
    uint32 scheduleDuration;
    uint64 nextConfigTime;
}

/// @title Ve33 Emission Rate Scheduler
/// @notice Policy contract that mints tokens according to timestamped emission-rate configurations.
contract Ve33EmissionRateScheduler is BaseLocker, BaseOwnableExecutor {
    /// @notice Thrown when a nonzero target is configured with a zero schedule duration.
    error InvalidScheduleDuration();
    /// @notice Thrown when a configuration timestamp is not both future and unaccounted.
    error InvalidConfigTime(uint64 startTime);
    /// @notice Thrown when the linked-list insertion or removal hint is incorrect.
    error InvalidPreviousConfigTime(uint64 previousConfigTime);
    /// @notice Thrown when a configuration already exists at a timestamp.
    error ConfigAlreadyScheduled(uint64 startTime);
    /// @notice Thrown when no configuration exists at a timestamp.
    error ConfigNotScheduled(uint64 startTime);
    /// @notice Thrown when an immediate update would modify an interval that has already been scheduled.
    error EmissionsAlreadyScheduled(uint64 untilTime);
    /// @notice Thrown when an immediate update would skip a pending configuration.
    error ConfigUpdateDue(uint64 startTime);
    /// @notice Thrown when the amount for a policy interval does not fit the Ve33 funding path.
    error EmissionAmountOverflow();
    /// @notice Thrown when no valid Ve33 timestamp can represent the end of a policy interval.
    error NoValidEmissionEnd();
    /// @notice Thrown when Ve33 funds an amount other than the amount calculated by the scheduler.
    error UnexpectedScheduledAmount(uint128 expected, uint128 actual);

    /// @notice Ekubo Core contract.
    ICore public immutable core;

    /// @notice Ve33 extension receiving scheduled emissions.
    Ve33 public immutable ve33;

    /// @notice Mintable token used as the Ve33 stake/reward token.
    IMintableERC20 public immutable token;

    /// @notice Packed policy emission rate and maximum preschedule duration.
    /// @dev The config type's `targetRate` field is interpreted here as an additive minting-policy rate.
    Ve33EmissionRateConfig public config;

    /// @notice First timestamp in the linked list of future configurations, or zero when empty.
    uint64 public nextConfigTime;

    /// @notice Arbitrary policy timestamp through which emissions have been accounted.
    uint64 public lastScheduledTime;

    /// @notice Valid Ve33 timestamp through which the last nonzero policy interval emits.
    uint64 public emissionEnd;

    /// @notice Unminted fractional Q32 token amount carried between calls under the current configuration.
    uint32 public rateRemainder;

    /// @notice Future configurations keyed by their arbitrary policy start timestamp.
    mapping(uint64 startTime => ScheduledEmissionRateConfig) public scheduledConfigs;

    /// @notice Emitted when the owner updates scheduler config.
    event ConfigSet(uint160 targetRate, uint32 scheduleDuration);

    /// @notice Emitted when the owner schedules a future configuration.
    event ConfigScheduled(uint64 indexed startTime, uint160 targetRate, uint32 scheduleDuration);

    /// @notice Emitted when a scheduled configuration becomes the policy at the accounting cursor.
    event ConfigActivated(uint64 indexed startTime, uint160 targetRate, uint32 scheduleDuration);

    /// @notice Emitted when the owner cancels a future configuration.
    event ConfigCancelled(uint64 indexed startTime);

    /// @notice Initializes the scheduler.
    /// @param owner Initial owner authorized to configure the target rate and duration.
    /// @param _core Ekubo Core contract.
    /// @param _ve33 Ve33 extension to schedule.
    constructor(address owner, ICore _core, Ve33 _ve33) BaseLocker(_core) BaseOwnableExecutor(owner) {
        core = _core;
        ve33 = _ve33;
        token = IMintableERC20(_ve33.stakeToken());
        lastScheduledTime = uint64(block.timestamp);
    }

    /// @notice Immediately sets the Q32 emission rate and maximum preschedule duration.
    /// @dev Reverts if a prior call has already accounted for future policy time or scheduled future emissions.
    /// @param targetRate Q32 token emission rate.
    /// @param scheduleDuration Maximum policy duration accounted by one call.
    function setConfig(uint160 targetRate, uint32 scheduleDuration) external onlyOwner {
        if (targetRate != 0 && scheduleDuration == 0) revert InvalidScheduleDuration();
        if (nextConfigTime != 0 && nextConfigTime <= block.timestamp) revert ConfigUpdateDue(nextConfigTime);

        uint64 accountedUntil = lastScheduledTime > emissionEnd ? lastScheduledTime : emissionEnd;
        if (accountedUntil > block.timestamp) revert EmissionsAlreadyScheduled(accountedUntil);

        config = createVe33EmissionRateConfig(targetRate, scheduleDuration);
        lastScheduledTime = uint64(block.timestamp);
        emissionEnd = uint64(block.timestamp);
        rateRemainder = 0;

        emit ConfigSet(targetRate, scheduleDuration);
    }

    /// @notice Inserts a future configuration into the timestamp-ordered linked list.
    /// @dev `previousConfigTime` is zero when inserting at the head. Otherwise it must identify the immediately
    ///      preceding scheduled configuration.
    /// @param startTime Arbitrary timestamp when the configuration begins.
    /// @param targetRate Q32 token emission rate.
    /// @param scheduleDuration Maximum policy duration accounted by one call.
    /// @param previousConfigTime Linked-list insertion hint.
    function scheduleConfig(uint64 startTime, uint160 targetRate, uint32 scheduleDuration, uint64 previousConfigTime)
        external
        onlyOwner
    {
        if (scheduleDuration == 0) revert InvalidScheduleDuration();
        if (startTime <= block.timestamp || startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);
        if (scheduledConfigs[startTime].scheduleDuration != 0) revert ConfigAlreadyScheduled(startTime);

        uint64 followingConfigTime;
        if (previousConfigTime == 0) {
            followingConfigTime = nextConfigTime;
            if (followingConfigTime != 0 && startTime >= followingConfigTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            nextConfigTime = startTime;
        } else {
            ScheduledEmissionRateConfig storage previousConfig = scheduledConfigs[previousConfigTime];
            if (previousConfig.scheduleDuration == 0 || previousConfigTime >= startTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }

            followingConfigTime = previousConfig.nextConfigTime;
            if (followingConfigTime != 0 && startTime >= followingConfigTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            previousConfig.nextConfigTime = startTime;
        }

        scheduledConfigs[startTime] = ScheduledEmissionRateConfig({
            targetRate: targetRate, scheduleDuration: scheduleDuration, nextConfigTime: followingConfigTime
        });

        emit ConfigScheduled(startTime, targetRate, scheduleDuration);
    }

    /// @notice Removes a future configuration from the timestamp-ordered linked list.
    /// @param startTime Timestamp of the configuration to remove.
    /// @param previousConfigTime Linked-list removal hint, or zero when removing the head.
    function cancelConfig(uint64 startTime, uint64 previousConfigTime) external onlyOwner {
        if (startTime <= block.timestamp || startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);

        ScheduledEmissionRateConfig memory scheduledConfig = scheduledConfigs[startTime];
        if (scheduledConfig.scheduleDuration == 0) revert ConfigNotScheduled(startTime);

        if (previousConfigTime == 0) {
            if (nextConfigTime != startTime) revert InvalidPreviousConfigTime(previousConfigTime);
            nextConfigTime = scheduledConfig.nextConfigTime;
        } else {
            ScheduledEmissionRateConfig storage previousConfig = scheduledConfigs[previousConfigTime];
            if (previousConfig.scheduleDuration == 0 || previousConfig.nextConfigTime != startTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            previousConfig.nextConfigTime = scheduledConfig.nextConfigTime;
        }

        delete scheduledConfigs[startTime];

        emit ConfigCancelled(startTime);
    }

    /// @notice Mints and schedules the exact whole-token amount accrued by the current policy interval.
    /// @dev Policy time advances at most `scheduleDuration` from the current block and never crosses the next arbitrary
    ///      configuration timestamp. The funded amount is fitted into a Ve33-valid time interval without changing
    ///      Ve33's timestamp validity rules.
    /// @return amount Amount of tokens minted and scheduled.
    function mintAndSchedule() external returns (uint128 amount) {
        amount = abi.decode(lock(""), (uint128));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory) internal override returns (bytes memory result) {
        if (nextConfigTime != 0 && nextConfigTime == lastScheduledTime) _activateNextConfig();

        Ve33EmissionRateConfig config_ = config;
        uint32 duration = config_.scheduleDuration();
        if (duration == 0) return abi.encode(uint128(0));

        uint64 nowTime = uint64(block.timestamp);
        uint64 horizon = nowTime + duration;
        uint64 nextConfigTime_ = nextConfigTime;
        if (nextConfigTime_ != 0 && nextConfigTime_ < horizon) {
            horizon = nextConfigTime_;
        }
        uint64 lastScheduledTime_ = lastScheduledTime;
        if (horizon <= lastScheduledTime_) return abi.encode(uint128(0));

        uint256 accruedQ32 = uint256(horizon - lastScheduledTime_) * config_.targetRate() + uint256(rateRemainder);
        uint256 amount256 = accruedQ32 >> 32;
        if (amount256 > type(uint128).max) revert EmissionAmountOverflow();
        uint128 amount = uint128(amount256);

        lastScheduledTime = horizon;
        rateRemainder = uint32(accruedQ32);

        if (amount == 0) {
            uint64 emissionEnd_ = emissionEnd;
            if (horizon > emissionEnd_) emissionEnd = _validTimeAtOrAfter(horizon);
        } else {
            uint64 emissionEnd_ = emissionEnd;
            uint64 realStartTime = emissionEnd_ > nowTime ? emissionEnd_ : nowTime;
            uint64 minimumEndTime = horizon > realStartTime ? horizon : realStartTime + 1;
            uint64 nextEmissionEnd = _validTimeAtOrAfter(minimumEndTime);
            uint256 emissionDuration = nextEmissionEnd - realStartTime;
            // Ve33 rounds the funded amount up. Because every valid emission duration is less than 2**32,
            // floor(amount * 2**32 / duration) makes that rounded funding amount exactly `amount`.
            uint160 emissionRate = uint160((uint256(amount) << 32) / emissionDuration);
            uint64 startTime = emissionEnd_ > nowTime ? emissionEnd_ : 0;

            uint128 scheduledAmount = Ve33Lib.scheduleEmissions(core, ve33, startTime, nextEmissionEnd, emissionRate);
            if (scheduledAmount != amount) revert UnexpectedScheduledAmount(amount, scheduledAmount);
            emissionEnd = nextEmissionEnd;
        }

        if (nextConfigTime_ != 0 && horizon == nextConfigTime_) _activateNextConfig();

        if (amount != 0) _mintTokenPayment(amount);
        return abi.encode(amount);
    }

    function _activateNextConfig() private {
        uint64 startTime = nextConfigTime;
        ScheduledEmissionRateConfig memory scheduledConfig = scheduledConfigs[startTime];

        config = createVe33EmissionRateConfig(scheduledConfig.targetRate, scheduledConfig.scheduleDuration);
        nextConfigTime = scheduledConfig.nextConfigTime;
        rateRemainder = 0;
        delete scheduledConfigs[startTime];

        emit ConfigActivated(startTime, scheduledConfig.targetRate, scheduledConfig.scheduleDuration);
    }

    function _validTimeAtOrAfter(uint64 minimumTime) private view returns (uint64 time) {
        uint256 nextTime = nextValidTime(block.timestamp, uint256(minimumTime) - 1);
        if (nextTime == 0) revert NoValidEmissionEnd();
        time = uint64(nextTime);
    }

    function _mintTokenPayment(uint128 amount) private {
        if (amount == 0) return;

        _callAccountant(abi.encodeWithSelector(IFlashAccountant.startPayments.selector, token));
        token.mint(address(ACCOUNTANT), amount);
        _callAccountant(abi.encodeWithSelector(IFlashAccountant.completePayments.selector, token));
    }

    function _callAccountant(bytes memory data) private {
        (bool success, bytes memory result) = address(ACCOUNTANT).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
