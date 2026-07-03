// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IFlashAccountant} from "./interfaces/IFlashAccountant.sol";
import {IMintableERC20} from "./interfaces/IMintableERC20.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {nextValidTime} from "./math/time.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "./types/ve33EmissionRateConfig.sol";

/// @title Ve33 Emission Rate Scheduler
/// @notice Ownable policy contract that mints tokens to maintain a target Ve33 global emission rate.
contract Ve33EmissionRateScheduler is BaseLocker, Ownable {
    using Ve33Lib for Ve33;

    /// @notice Thrown when a nonzero target is configured with a zero schedule duration.
    error InvalidScheduleDuration();

    /// @notice Ekubo Core contract.
    ICore public immutable core;

    /// @notice Ve33 extension receiving scheduled emissions.
    Ve33 public immutable ve33;

    /// @notice Mintable token used as the Ve33 stake/reward token.
    IMintableERC20 public immutable token;

    /// @notice Packed target emission rate and schedule duration.
    Ve33EmissionRateConfig public config;

    /// @notice Emitted when the owner updates scheduler config.
    event ConfigSet(uint160 targetRate, uint32 scheduleDuration);

    /// @notice Emitted when tokens are minted and scheduled to cover a rate shortfall.
    event EmissionsMintedAndScheduled(uint64 endTime, uint160 rewardRate, uint128 amount);

    /// @notice Initializes the scheduler.
    /// @param owner Initial owner authorized to configure the target rate and duration.
    /// @param _core Ekubo Core contract.
    /// @param _ve33 Ve33 extension to schedule.
    constructor(address owner, ICore _core, Ve33 _ve33) BaseLocker(_core) {
        core = _core;
        ve33 = _ve33;
        token = IMintableERC20(_ve33.stakeToken());
        _initializeOwner(owner);
    }

    /// @notice Sets the target global Q32 emission rate and schedule duration.
    /// @param targetRate Target global Q32 emission rate.
    /// @param scheduleDuration Schedule duration in seconds.
    function setConfig(uint160 targetRate, uint32 scheduleDuration) external onlyOwner {
        if (targetRate != 0 && scheduleDuration == 0) revert InvalidScheduleDuration();

        config = createVe33EmissionRateConfig(targetRate, scheduleDuration);

        emit ConfigSet(targetRate, scheduleDuration);
    }

    /// @notice Mints and schedules enough tokens to raise Ve33's global emission rate to the configured target.
    /// @dev Anyone can call this. Returns zero if the current rate is already at or above target.
    /// @return amount Amount of tokens minted and scheduled.
    function mintAndSchedule() external returns (uint128 amount) {
        amount = abi.decode(lock(""), (uint128));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory) internal override returns (bytes memory result) {
        Ve33EmissionRateConfig config_ = config;
        uint160 targetRate = config_.targetRate();

        ve33.accrueEmissions();

        uint160 currentRate = ve33.emissionRate();
        if (currentRate >= targetRate) return abi.encode(uint128(0));

        uint32 scheduleDuration = config_.scheduleDuration();
        if (scheduleDuration == 0) revert InvalidScheduleDuration();

        uint64 endTime = uint64(nextValidTime(block.timestamp, block.timestamp + uint256(scheduleDuration) - 1));
        uint160 rewardRate;
        unchecked {
            rewardRate = targetRate - currentRate;
        }

        uint128 amount = Ve33Lib.scheduleEmissions(core, ve33, 0, endTime, rewardRate);
        _mintTokenPayment(amount);

        emit EmissionsMintedAndScheduled(endTime, rewardRate, amount);

        result = abi.encode(amount);
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
