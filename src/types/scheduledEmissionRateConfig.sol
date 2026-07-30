// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ve33EmissionRateConfig} from "./ve33EmissionRateConfig.sol";

/// @notice A future emission-rate configuration and the timestamp of the following configuration.
/// @dev Bit layout:
///      - bits 0-191: emissionRateConfig
///      - bits 192-255: nextConfigTime
type ScheduledEmissionRateConfig is bytes32;

using {emissionRateConfig, nextConfigTime, parse} for ScheduledEmissionRateConfig global;

/// @notice Returns the emission-rate configuration that begins at this node's timestamp.
function emissionRateConfig(ScheduledEmissionRateConfig scheduledConfig) pure returns (Ve33EmissionRateConfig config) {
    assembly ("memory-safe") {
        config := shr(64, shl(64, scheduledConfig))
    }
}

/// @notice Returns the timestamp of the next configuration in the linked list, or zero at the tail.
function nextConfigTime(ScheduledEmissionRateConfig scheduledConfig) pure returns (uint64 time) {
    assembly ("memory-safe") {
        time := shr(192, scheduledConfig)
    }
}

/// @notice Returns both fields in the packed scheduled configuration.
function parse(ScheduledEmissionRateConfig scheduledConfig)
    pure
    returns (Ve33EmissionRateConfig config, uint64 nextConfigTime_)
{
    assembly ("memory-safe") {
        config := shr(64, shl(64, scheduledConfig))
        nextConfigTime_ := shr(192, scheduledConfig)
    }
}

/// @notice Creates a packed scheduled emission-rate configuration.
function createScheduledEmissionRateConfig(Ve33EmissionRateConfig config, uint64 nextConfigTime_)
    pure
    returns (ScheduledEmissionRateConfig scheduledConfig)
{
    assembly ("memory-safe") {
        scheduledConfig := or(shr(64, shl(64, config)), shl(192, nextConfigTime_))
    }
}
