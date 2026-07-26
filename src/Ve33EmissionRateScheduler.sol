// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseOwnableExecutor} from "./base/BaseOwnableExecutor.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IFlashAccountant} from "./interfaces/IFlashAccountant.sol";
import {IMintableERC20} from "./interfaces/IMintableERC20.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {computeStepSize} from "./math/time.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "./types/ve33EmissionRateConfig.sol";

/// @title Ve33 Emission Rate Scheduler
/// @notice Policy contract that mints tokens to maintain a target Ve33 global emission rate.
contract Ve33EmissionRateScheduler is BaseLocker, BaseOwnableExecutor {
    using Ve33Lib for Ve33;

    /// @notice Thrown when a nonzero target is configured with a zero schedule duration.
    error InvalidScheduleDuration();

    /// @notice Ekubo Core contract.
    ICore public immutable core;

    /// @notice Ve33 extension receiving scheduled emissions.
    Ve33 public immutable ve33;

    /// @notice Mintable token used as the Ve33 stake/reward token.
    IMintableERC20 public immutable token;

    /// @notice Packed target emission rate and maximum schedule duration.
    Ve33EmissionRateConfig public config;

    /// @notice Emitted when the owner updates scheduler config.
    event ConfigSet(uint160 targetRate, uint32 scheduleDuration);

    /// @notice Initializes the scheduler.
    /// @param owner Initial owner authorized to configure the target rate and duration.
    /// @param _core Ekubo Core contract.
    /// @param _ve33 Ve33 extension to schedule.
    constructor(address owner, ICore _core, Ve33 _ve33) BaseLocker(_core) BaseOwnableExecutor(owner) {
        core = _core;
        ve33 = _ve33;
        token = IMintableERC20(_ve33.stakeToken());
    }

    /// @notice Sets the target global Q32 emission rate and maximum schedule duration.
    /// @param targetRate Target global Q32 emission rate.
    /// @param scheduleDuration Maximum schedule duration in seconds.
    function setConfig(uint160 targetRate, uint32 scheduleDuration) external onlyOwner {
        if (targetRate != 0 && scheduleDuration == 0) revert InvalidScheduleDuration();

        config = createVe33EmissionRateConfig(targetRate, scheduleDuration);

        emit ConfigSet(targetRate, scheduleDuration);
    }

    /// @notice Mints and schedules enough tokens to raise Ve33's global emission rate to the configured target.
    /// @dev Anyone can call this. Returns zero when the target is zero or the current and forward-looking schedule
    ///      are already at or above target through the horizon.
    /// @return amount Amount of tokens minted and scheduled.
    function mintAndSchedule() external returns (uint128 amount) {
        amount = abi.decode(lock(""), (uint128));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory) internal override returns (bytes memory result) {
        Ve33EmissionRateConfig config_ = config;
        uint160 target = config_.targetRate();
        if (target == 0) return abi.encode(uint128(0));

        uint32 duration = config_.scheduleDuration();
        if (duration == 0) revert InvalidScheduleDuration();

        uint64 nowTime = uint64(block.timestamp);
        uint256 maxEndTime = block.timestamp + uint256(duration);
        uint256 stepSize = computeStepSize(block.timestamp, maxEndTime);
        uint64 horizon = uint64(maxEndTime - (maxEndTime % stepSize));
        if (horizon <= nowTime) return abi.encode(uint128(0));

        ve33.accrueEmissions();

        uint160 projectedRate = ve33.emissionRate();
        uint64 cursor = nowTime;
        uint128 totalAmount;

        while (cursor < horizon) {
            (uint64 nextChangeTime,) = ve33.nextEmissionRateChangeTime(cursor);
            uint64 intervalEnd = (nextChangeTime == 0 || nextChangeTime > horizon) ? horizon : nextChangeTime;

            if (projectedRate < target) {
                uint160 shortfall;
                unchecked {
                    shortfall = target - projectedRate;
                }

                uint64 startTime = cursor == nowTime ? 0 : cursor;
                uint128 scheduleAmount = Ve33Lib.scheduleEmissions(core, ve33, startTime, intervalEnd, shortfall);
                totalAmount += scheduleAmount;
                projectedRate = target;
            }

            if (intervalEnd == horizon) break;

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

        if (totalAmount != 0) _mintTokenPayment(totalAmount);
        return abi.encode(totalAmount);
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
