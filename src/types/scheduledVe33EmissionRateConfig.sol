// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ve33EmissionRateConfig} from "./ve33EmissionRateConfig.sol";

/// @notice A Ve33 emission-rate configuration and the timestamp of the next scheduled configuration.
/// @dev Bit layout:
///      - bits 0-191: emissionRateConfig
///      - bits 192-255: nextConfigTime
type ScheduledVe33EmissionRateConfig is bytes32;

using {emissionRateConfig, nextConfigTime, parse} for ScheduledVe33EmissionRateConfig global;

/// @notice Returns the embedded emission-rate configuration.
function emissionRateConfig(ScheduledVe33EmissionRateConfig scheduledConfig)
    pure
    returns (Ve33EmissionRateConfig config)
{
    assembly ("memory-safe") {
        config := shr(64, shl(64, scheduledConfig))
    }
}

/// @notice Returns the timestamp of the next configuration in the linked list, or zero at the tail.
function nextConfigTime(ScheduledVe33EmissionRateConfig scheduledConfig) pure returns (uint64 time) {
    assembly ("memory-safe") {
        time := shr(192, scheduledConfig)
    }
}

/// @notice Returns both fields in the packed scheduled configuration.
function parse(ScheduledVe33EmissionRateConfig scheduledConfig)
    pure
    returns (Ve33EmissionRateConfig config, uint64 nextConfigTime_)
{
    assembly ("memory-safe") {
        config := shr(64, shl(64, scheduledConfig))
        nextConfigTime_ := shr(192, scheduledConfig)
    }
}

/// @notice Creates a packed scheduled emission-rate configuration.
function createScheduledVe33EmissionRateConfig(Ve33EmissionRateConfig config, uint64 nextConfigTime_)
    pure
    returns (ScheduledVe33EmissionRateConfig scheduledConfig)
{
    assembly ("memory-safe") {
        scheduledConfig := or(shr(64, shl(64, config)), shl(192, nextConfigTime_))
    }
}
