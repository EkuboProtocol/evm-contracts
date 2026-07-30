// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseOwnableExecutor} from "./base/BaseOwnableExecutor.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {computeStepSize, nextValidTime} from "./math/time.sol";
import {
    ScheduledVe33EmissionRateConfig,
    createScheduledVe33EmissionRateConfig
} from "./types/scheduledVe33EmissionRateConfig.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "./types/ve33EmissionRateConfig.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Ve33 Emission Rate Scheduler
/// @notice Policy contract that spends prefunded tokens according to timestamped emission-rate configurations.
/// @dev Inherits Solady's non-value-forwarding Multicallable and an ETH receive path through BaseOwnableExecutor.
contract Ve33EmissionRateScheduler is BaseLocker, BaseOwnableExecutor {
    using FlashAccountantLib for *;
    using Ve33Lib for Ve33;

    /// @notice Thrown when a nonzero minimum rate is configured with a zero schedule duration.
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
    /// @notice Ekubo Core contract.
    ICore public immutable core;

    /// @notice Ve33 extension receiving scheduled emissions.
    Ve33 public immutable ve33;

    /// @notice Token used as the Ve33 stake/reward token, or address(0) for the native token.
    address public immutable stakeToken;

    /// @notice Packed active emission-rate configuration and head of the future-configuration linked list.
    ScheduledVe33EmissionRateConfig public config;

    /// @notice Arbitrary policy timestamp through which emissions have been accounted.
    uint64 public lastScheduledTime;

    /// @notice Valid Ve33 timestamp through which projected emissions have been covered.
    uint64 public emissionEnd;

    /// @notice Unpaid fractional Q32 token amount carried between calls under the current configuration.
    uint32 public rateRemainder;

    /// @notice Future configurations keyed by their arbitrary policy start timestamp.
    mapping(uint64 startTime => ScheduledVe33EmissionRateConfig) public scheduledConfigs;

    /// @notice Emitted when the owner updates scheduler config.
    event ConfigSet(uint160 minEmissionsRate, uint32 scheduleDuration);

    /// @notice Emitted when the owner schedules a future configuration.
    event ConfigScheduled(uint64 indexed startTime, uint160 minEmissionsRate, uint32 scheduleDuration);

    /// @notice Emitted when a scheduled configuration becomes the policy at the accounting cursor.
    event ConfigActivated(uint64 indexed startTime, uint160 minEmissionsRate, uint32 scheduleDuration);

    /// @notice Emitted when the owner cancels a future configuration.
    event ConfigCancelled(uint64 indexed startTime);

    /// @notice Initializes the scheduler.
    /// @param owner Initial owner authorized to configure the minimum rate and duration.
    /// @param _core Ekubo Core contract.
    /// @param _ve33 Ve33 extension to schedule.
    constructor(address owner, ICore _core, Ve33 _ve33) BaseLocker(_core) BaseOwnableExecutor(owner) {
        core = _core;
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
        lastScheduledTime = uint64(block.timestamp);
    }

    /// @notice Immediately sets the minimum global Q32 emissions rate and maximum preschedule duration.
    /// @dev Reverts if a prior call has already accounted for future policy time or scheduled future emissions.
    /// @param minEmissionsRate Minimum global Q32 token emissions rate.
    /// @param scheduleDuration Maximum policy duration accounted by one call.
    function setConfig(uint160 minEmissionsRate, uint32 scheduleDuration) external onlyOwner {
        if (minEmissionsRate != 0 && scheduleDuration == 0) revert InvalidScheduleDuration();
        uint64 nextConfigTime_ = config.nextConfigTime();
        if (nextConfigTime_ != 0 && nextConfigTime_ <= block.timestamp) revert ConfigUpdateDue(nextConfigTime_);

        uint64 accountedUntil = lastScheduledTime > emissionEnd ? lastScheduledTime : emissionEnd;
        if (accountedUntil > block.timestamp) revert EmissionsAlreadyScheduled(accountedUntil);

        config = createScheduledVe33EmissionRateConfig(
            createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration), nextConfigTime_
        );
        lastScheduledTime = uint64(block.timestamp);
        emissionEnd = uint64(block.timestamp);
        rateRemainder = 0;

        emit ConfigSet(minEmissionsRate, scheduleDuration);
    }

    /// @notice Inserts a future configuration into the timestamp-ordered linked list.
    /// @dev `previousConfigTime` is zero when inserting at the head. Otherwise it must identify the immediately
    ///      preceding scheduled configuration.
    /// @param startTime Arbitrary timestamp when the configuration begins.
    /// @param minEmissionsRate Minimum global Q32 token emissions rate.
    /// @param scheduleDuration Maximum policy duration accounted by one call.
    /// @param previousConfigTime Linked-list insertion hint.
    function scheduleConfig(
        uint64 startTime,
        uint160 minEmissionsRate,
        uint32 scheduleDuration,
        uint64 previousConfigTime
    ) external onlyOwner {
        if (scheduleDuration == 0) revert InvalidScheduleDuration();
        if (startTime <= block.timestamp || startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);
        if (scheduledConfigs[startTime].emissionRateConfig().scheduleDuration() != 0) {
            revert ConfigAlreadyScheduled(startTime);
        }

        uint64 followingConfigTime;
        if (previousConfigTime == 0) {
            ScheduledVe33EmissionRateConfig config_ = config;
            followingConfigTime = config_.nextConfigTime();
            if (followingConfigTime != 0 && startTime >= followingConfigTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            config = createScheduledVe33EmissionRateConfig(config_.emissionRateConfig(), startTime);
        } else {
            ScheduledVe33EmissionRateConfig previousConfig = scheduledConfigs[previousConfigTime];
            Ve33EmissionRateConfig previousRateConfig = previousConfig.emissionRateConfig();
            if (previousRateConfig.scheduleDuration() == 0 || previousConfigTime >= startTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }

            followingConfigTime = previousConfig.nextConfigTime();
            if (followingConfigTime != 0 && startTime >= followingConfigTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            scheduledConfigs[previousConfigTime] = createScheduledVe33EmissionRateConfig(previousRateConfig, startTime);
        }

        scheduledConfigs[startTime] = createScheduledVe33EmissionRateConfig(
            createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration), followingConfigTime
        );

        emit ConfigScheduled(startTime, minEmissionsRate, scheduleDuration);
    }

    /// @notice Removes a future configuration from the timestamp-ordered linked list.
    /// @param startTime Timestamp of the configuration to remove.
    /// @param previousConfigTime Linked-list removal hint, or zero when removing the head.
    function cancelConfig(uint64 startTime, uint64 previousConfigTime) external onlyOwner {
        if (startTime <= block.timestamp || startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);

        ScheduledVe33EmissionRateConfig scheduledConfig = scheduledConfigs[startTime];
        Ve33EmissionRateConfig rateConfig = scheduledConfig.emissionRateConfig();
        if (rateConfig.scheduleDuration() == 0) revert ConfigNotScheduled(startTime);

        if (previousConfigTime == 0) {
            ScheduledVe33EmissionRateConfig config_ = config;
            if (config_.nextConfigTime() != startTime) revert InvalidPreviousConfigTime(previousConfigTime);
            config =
                createScheduledVe33EmissionRateConfig(config_.emissionRateConfig(), scheduledConfig.nextConfigTime());
        } else {
            ScheduledVe33EmissionRateConfig previousConfig = scheduledConfigs[previousConfigTime];
            Ve33EmissionRateConfig previousRateConfig = previousConfig.emissionRateConfig();
            if (previousRateConfig.scheduleDuration() == 0 || previousConfig.nextConfigTime() != startTime) {
                revert InvalidPreviousConfigTime(previousConfigTime);
            }
            scheduledConfigs[previousConfigTime] =
                createScheduledVe33EmissionRateConfig(previousRateConfig, scheduledConfig.nextConfigTime());
        }

        scheduledConfigs[startTime] = ScheduledVe33EmissionRateConfig.wrap(bytes32(0));

        emit ConfigCancelled(startTime);
    }

    /// @notice Pays and schedules the shortfall required to maintain the configured minimum emissions rate.
    /// @dev Policy time advances at most `scheduleDuration` from the current block and never crosses the next arbitrary
    ///      configuration timestamp. With no other emissions, the exact whole-token amount accrued by the policy is
    ///      fitted into a Ve33-valid interval at no less than the configured minimum rate. Existing emissions reduce
    ///      the amount this scheduler must fund.
    /// @return amount Amount of prefunded tokens paid and scheduled.
    function scheduleEmissions() external returns (uint128 amount) {
        amount = abi.decode(lock(""), (uint128));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory) internal override returns (bytes memory result) {
        ScheduledVe33EmissionRateConfig config_ = config;
        uint64 nextConfigTime_ = config_.nextConfigTime();
        if (nextConfigTime_ != 0 && nextConfigTime_ == lastScheduledTime) {
            _activateNextConfig();
            config_ = config;
            nextConfigTime_ = config_.nextConfigTime();
        }

        Ve33EmissionRateConfig rateConfig = config_.emissionRateConfig();
        uint32 duration = rateConfig.scheduleDuration();
        if (duration == 0) return abi.encode(uint128(0));

        uint64 nowTime = uint64(block.timestamp);
        uint64 horizon = nowTime + duration;
        if (nextConfigTime_ != 0 && nextConfigTime_ < horizon) {
            horizon = nextConfigTime_;
        }
        uint64 lastScheduledTime_ = lastScheduledTime;
        if (horizon <= lastScheduledTime_) return abi.encode(uint128(0));

        uint160 minEmissionsRate = rateConfig.minEmissionsRate();
        uint256 accruedQ32 = uint256(horizon - lastScheduledTime_) * minEmissionsRate + uint256(rateRemainder);
        uint256 policyAmount256 = accruedQ32 >> 32;
        if (policyAmount256 > type(uint128).max) revert EmissionAmountOverflow();
        uint128 policyAmount = uint128(policyAmount256);

        lastScheduledTime = horizon;
        rateRemainder = uint32(accruedQ32);

        uint128 amount;
        if (policyAmount == 0) {
            uint64 emissionEnd_ = emissionEnd;
            if (horizon > emissionEnd_) emissionEnd = _validTimeAtOrAfter(horizon);
        } else {
            uint64 emissionEnd_ = emissionEnd;
            uint64 realStartTime = emissionEnd_ > nowTime ? emissionEnd_ : nowTime;
            uint256 maximumEmissionDuration = (uint256(policyAmount) << 32) / minEmissionsRate;
            if (maximumEmissionDuration > type(uint32).max) maximumEmissionDuration = type(uint32).max;

            uint256 maximumEndTime = uint256(realStartTime) + maximumEmissionDuration;
            uint256 latestValidTime = block.timestamp + type(uint32).max;
            if (maximumEndTime > latestValidTime) maximumEndTime = latestValidTime;

            uint64 nextEmissionEnd = _validTimeAtOrBefore(maximumEndTime, realStartTime);
            uint256 emissionDuration = nextEmissionEnd - realStartTime;
            // Ve33 rounds the funded amount up. Because every valid emission duration is less than 2**32,
            // floor(amount * 2**32 / duration) funds exactly `policyAmount` when no existing emissions contribute.
            // Choosing a duration no greater than policyAmount / minEmissionsRate also keeps this fitted minimum rate
            // at or above the configured minimum.
            uint160 fittedMinEmissionsRate = uint160((uint256(policyAmount) << 32) / emissionDuration);

            amount = _scheduleRateShortfall(realStartTime, nextEmissionEnd, minEmissionsRate, fittedMinEmissionsRate);
            emissionEnd = nextEmissionEnd;
        }

        if (nextConfigTime_ != 0 && horizon == nextConfigTime_) _activateNextConfig();

        if (amount != 0) _payToken(amount);
        return abi.encode(amount);
    }

    function _activateNextConfig() private {
        uint64 startTime = config.nextConfigTime();
        ScheduledVe33EmissionRateConfig scheduledConfig = scheduledConfigs[startTime];
        Ve33EmissionRateConfig rateConfig = scheduledConfig.emissionRateConfig();

        config = scheduledConfig;
        rateRemainder = 0;
        scheduledConfigs[startTime] = ScheduledVe33EmissionRateConfig.wrap(bytes32(0));

        emit ConfigActivated(startTime, rateConfig.minEmissionsRate(), rateConfig.scheduleDuration());
    }

    function _validTimeAtOrAfter(uint64 minimumTime) private view returns (uint64 time) {
        uint256 nextTime = nextValidTime(block.timestamp, uint256(minimumTime) - 1);
        if (nextTime == 0) revert NoValidEmissionEnd();
        time = uint64(nextTime);
    }

    function _validTimeAtOrBefore(uint256 maximumTime, uint64 afterTime) private view returns (uint64 time) {
        uint256 stepSize = computeStepSize(block.timestamp, maximumTime);
        uint256 previousTime = maximumTime - (maximumTime % stepSize);
        if (previousTime <= afterTime) revert NoValidEmissionEnd();
        time = uint64(previousTime);
    }

    function _scheduleRateShortfall(
        uint64 startTime,
        uint64 endTime,
        uint160 minEmissionsRate,
        uint160 fittedMinEmissionsRate
    ) private returns (uint128 totalAmount) {
        ve33.accrueEmissions();

        uint160 projectedRate = ve33.emissionRate();
        uint64 nowTime = uint64(block.timestamp);
        uint64 cursor = nowTime;

        while (cursor < endTime) {
            (uint64 nextChangeTime,) = ve33.nextEmissionRateChangeTime(cursor);
            uint64 intervalEnd = (nextChangeTime == 0 || nextChangeTime > endTime) ? endTime : nextChangeTime;
            uint64 intervalStart = cursor > startTime ? cursor : startTime;

            if (intervalStart < intervalEnd && projectedRate < minEmissionsRate) {
                uint160 shortfall;
                unchecked {
                    shortfall = fittedMinEmissionsRate - projectedRate;
                }

                uint64 scheduleStartTime = intervalStart == nowTime ? 0 : intervalStart;
                totalAmount += Ve33Lib.scheduleEmissions(core, ve33, scheduleStartTime, intervalEnd, shortfall);
                projectedRate = fittedMinEmissionsRate;
            }

            if (intervalEnd == endTime) break;

            cursor = intervalEnd;
            int256 delta = ve33.emissionRateDeltaAtTime(cursor);
            if (delta < 0) {
                uint256 decrease = uint256(-delta);
                projectedRate = decrease >= projectedRate ? 0 : projectedRate - uint160(decrease);
            } else if (delta > 0) {
                unchecked {
                    projectedRate += uint160(uint256(delta));
                }
            }
        }
    }

    function _payToken(uint128 amount) private {
        address stakeToken_ = stakeToken;
        if (stakeToken_ == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
        } else {
            ACCOUNTANT.pay(stakeToken_, amount);
        }
    }
}
