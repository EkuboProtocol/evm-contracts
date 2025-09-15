// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

/// @notice The minimum tick value supported by the protocol
int32 constant MIN_TICK = -88722835;

/// @notice The maximum tick value supported by the protocol
int32 constant MAX_TICK = 88722835;

/// @notice The maximum tick magnitude (absolute value of MAX_TICK)
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);

/// @notice The maximum allowed tick spacing for pools
uint32 constant MAX_TICK_SPACING = 698605;

/// @notice Special tick spacing value indicating full-range-only pools
uint32 constant FULL_RANGE_ONLY_TICK_SPACING = 0;

/// @notice Address used to represent the native token (ETH) within the protocol
address constant NATIVE_TOKEN_ADDRESS = address(0);
