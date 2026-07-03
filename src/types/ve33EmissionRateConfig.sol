// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type Ve33EmissionRateConfig is bytes32;

using {targetRate, scheduleDuration} for Ve33EmissionRateConfig global;

/// @notice Returns the target global Q32 emission rate.
function targetRate(Ve33EmissionRateConfig config) pure returns (uint160 rate) {
    assembly ("memory-safe") {
        rate := shr(96, shl(96, config))
    }
}

/// @notice Returns the target schedule duration in seconds.
function scheduleDuration(Ve33EmissionRateConfig config) pure returns (uint32 duration) {
    assembly ("memory-safe") {
        duration := and(shr(160, config), 0xffffffff)
    }
}

/// @notice Creates a packed Ve33 emission-rate scheduler config.
function createVe33EmissionRateConfig(uint160 targetRate_, uint32 scheduleDuration_)
    pure
    returns (Ve33EmissionRateConfig config)
{
    assembly ("memory-safe") {
        config := or(shr(96, shl(96, targetRate_)), shl(160, scheduleDuration_))
    }
}
