// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed minimum Ve33 emissions rate and scheduler lookahead duration.
/// @dev Bit layout:
///      - bits 0-159: minEmissionsRate
///      - bits 160-191: scheduleDuration
type Ve33EmissionRateConfig is uint192;

using {minEmissionsRate, scheduleDuration} for Ve33EmissionRateConfig global;

/// @notice Returns the minimum global Q32 emissions rate.
function minEmissionsRate(Ve33EmissionRateConfig config) pure returns (uint160 rate) {
    assembly ("memory-safe") {
        rate := shr(96, shl(96, config))
    }
}

/// @notice Returns the maximum scheduling lookahead in seconds.
function scheduleDuration(Ve33EmissionRateConfig config) pure returns (uint32 duration) {
    assembly ("memory-safe") {
        duration := and(shr(160, config), 0xffffffff)
    }
}

/// @notice Creates a packed Ve33 emission-rate scheduler config.
function createVe33EmissionRateConfig(uint160 minEmissionsRate_, uint32 scheduleDuration_)
    pure
    returns (Ve33EmissionRateConfig config)
{
    assembly ("memory-safe") {
        config := or(shr(96, shl(96, minEmissionsRate_)), shl(160, scheduleDuration_))
    }
}
