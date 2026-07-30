// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseOwnableExecutor} from "./base/BaseOwnableExecutor.sol";
import {Ve33, VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA} from "./extensions/Ve33.sol";
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

    /// @notice Thrown when a zero schedule duration is supplied where a nonzero duration is required.
    error InvalidScheduleDuration();
    /// @notice Thrown when a minimum rate could produce a fitted Ve33 rate above its per-time delta limit.
    error MinEmissionsRateTooHigh(uint160 minEmissionsRate);
    /// @notice Thrown when a configuration timestamp is ineligible for the requested insertion or removal.
    error InvalidConfigTime(uint64 startTime);
    /// @notice Thrown when the linked-list insertion or removal hint is incorrect.
    error InvalidPreviousConfigTime(uint64 previousConfigTime);
    /// @notice Thrown when a configuration already exists at a timestamp.
    error ConfigAlreadyScheduled(uint64 startTime);
    /// @notice Thrown when no configuration exists at a timestamp.
    error ConfigNotScheduled(uint64 startTime);
    /// @notice Thrown when an immediate update would skip a pending configuration.
    error ConfigUpdateDue(uint64 startTime);
    /// @notice Thrown when no valid Ve33 timestamp can represent the end of a policy interval.
    error NoValidEmissionEnd();
    /// @notice Ekubo Core contract.
    ICore public immutable core;

    /// @notice Ve33 extension receiving scheduled emissions.
    Ve33 public immutable ve33;

    /// @notice Token used as the Ve33 stake/reward token, or address(0) for the native token.
    address public immutable stakeToken;

    /// @notice Largest accepted minimum rate.
    /// @dev A call accounts at most `uint32.max` policy seconds. Even if that whole amount is fitted into one second,
    ///      this bound keeps the resulting rate within Ve33's absolute emission-rate-delta limit. It also implies that
    ///      every policy amount fits uint128.
    uint160 public constant MAX_MIN_EMISSIONS_RATE = uint160(VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA / type(uint32).max);

    /// @notice Packed active emission-rate configuration and head of the future-configuration linked list.
    ScheduledVe33EmissionRateConfig public config;

    /// @notice Arbitrary policy timestamp through which emissions have been accounted.
    uint64 public lastScheduledTime;

    /// @notice Execution-time cursor through which projected emissions have been covered.
    /// @dev A future value is a Ve33-valid schedule endpoint. An immediate config update only advances a stale cursor
    ///      to the current time; it never rewinds already-funded emissions.
    uint64 public emissionEnd;

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

    /// @notice Returns the current packed configuration and every queued configuration timestamp in ascending order.
    /// @dev Traverses the timestamp-linked list twice: first to determine its length, then to populate the result.
    function getConfigState()
        external
        view
        returns (ScheduledVe33EmissionRateConfig currentConfig, uint64[] memory scheduledConfigTimes)
    {
        currentConfig = config;
        uint64 nextConfigTime_ = currentConfig.nextConfigTime();
        uint256 length;
        while (nextConfigTime_ != 0) {
            length++;
            nextConfigTime_ = scheduledConfigs[nextConfigTime_].nextConfigTime();
        }

        scheduledConfigTimes = new uint64[](length);
        nextConfigTime_ = currentConfig.nextConfigTime();
        for (uint256 i; i < length; i++) {
            scheduledConfigTimes[i] = nextConfigTime_;
            nextConfigTime_ = scheduledConfigs[nextConfigTime_].nextConfigTime();
        }
    }

    /// @notice Immediately sets the minimum global Q32 emissions rate and maximum preschedule duration.
    /// @dev The update takes effect at the later of the current block and `lastScheduledTime`. It cannot cancel a Ve33
    ///      stream that was already funded, but it prevents permissionless callers from extending the old policy.
    /// @param minEmissionsRate Minimum global Q32 token emissions rate.
    /// @param scheduleDuration Maximum policy duration accounted by one call.
    function setConfig(uint160 minEmissionsRate, uint32 scheduleDuration) external onlyOwner {
        _validateConfig(minEmissionsRate, scheduleDuration, false);
        uint64 nextConfigTime_ = config.nextConfigTime();
        if (nextConfigTime_ != 0 && nextConfigTime_ <= block.timestamp) revert ConfigUpdateDue(nextConfigTime_);

        config = createScheduledVe33EmissionRateConfig(
            createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration), nextConfigTime_
        );
        uint64 nowTime = uint64(block.timestamp);
        if (lastScheduledTime < nowTime) lastScheduledTime = nowTime;
        if (emissionEnd < nowTime) emissionEnd = nowTime;

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
        _validateConfig(minEmissionsRate, scheduleDuration, true);
        if (startTime <= block.timestamp || startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);
        if (ScheduledVe33EmissionRateConfig.unwrap(scheduledConfigs[startTime]) != bytes32(0)) {
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
    /// @dev A wall-clock-due node remains cancellable until policy accounting reaches its timestamp.
    /// @param startTime Timestamp of the configuration to remove.
    /// @param previousConfigTime Linked-list removal hint, or zero when removing the head.
    function cancelConfig(uint64 startTime, uint64 previousConfigTime) external onlyOwner {
        if (startTime <= lastScheduledTime) revert InvalidConfigTime(startTime);

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
        uint64 nowTime = uint64(block.timestamp);
        if (duration == 0) {
            if (nextConfigTime_ == 0 || nextConfigTime_ > nowTime) return abi.encode(uint128(0));

            lastScheduledTime = nextConfigTime_;
            _activateNextConfig();
            config_ = config;
            nextConfigTime_ = config_.nextConfigTime();
            rateConfig = config_.emissionRateConfig();
            duration = rateConfig.scheduleDuration();
        }

        uint64 lastScheduledTime_ = lastScheduledTime;
        uint256 horizon256 = block.timestamp + duration;
        uint256 maximumAccountingHorizon = uint256(lastScheduledTime_) + type(uint32).max;
        if (horizon256 > maximumAccountingHorizon) horizon256 = maximumAccountingHorizon;
        if (nextConfigTime_ != 0 && nextConfigTime_ < horizon256) horizon256 = nextConfigTime_;
        uint64 horizon = uint64(horizon256);
        if (horizon <= lastScheduledTime_) return abi.encode(uint128(0));

        uint160 minEmissionsRate = rateConfig.minEmissionsRate();
        uint128 policyAmount = uint128((uint256(horizon - lastScheduledTime_) * minEmissionsRate) >> 32);

        lastScheduledTime = horizon;

        uint128 amount;
        if (policyAmount == 0) {
            uint64 emissionEnd_ = emissionEnd;
            if (horizon > emissionEnd_) emissionEnd = _validTimeAtOrAfter(horizon);
        } else {
            uint64 emissionEnd_ = emissionEnd;
            uint64 realStartTime = emissionEnd_ > nowTime ? emissionEnd_ : nowTime;
            uint256 maximumEmissionDuration = (uint256(policyAmount) << 32) / minEmissionsRate;

            uint256 maximumEndTime = uint256(realStartTime) + maximumEmissionDuration;
            uint256 latestValidTime = block.timestamp + type(uint32).max;
            if (maximumEndTime > latestValidTime) maximumEndTime = latestValidTime;

            uint64 nextEmissionEnd = _validTimeAtOrBefore(maximumEndTime, realStartTime);
            uint256 emissionDuration = nextEmissionEnd - realStartTime;
            // Choosing a duration no greater than policyAmount / minEmissionsRate keeps this fitted minimum rate at
            // or above the configured minimum. MAX_MIN_EMISSIONS_RATE guarantees the fitted rate fits uint160 and
            // remains within Ve33's per-time delta limit, even when this valid interval is only one second.
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

    function _validateConfig(uint160 minEmissionsRate, uint32 scheduleDuration, bool requireDuration) private pure {
        if (scheduleDuration == 0 && (requireDuration || minEmissionsRate != 0)) revert InvalidScheduleDuration();
        if (minEmissionsRate > MAX_MIN_EMISSIONS_RATE) revert MinEmissionsRateTooHigh(minEmissionsRate);
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
