// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

/// @title Protocol Constants
/// @notice Contains all constant values used throughout the Ekubo Protocol
/// @dev These constants define the boundaries and special values for the protocol's operation

/// @notice The minimum tick value supported by the protocol
/// @dev Corresponds to the minimum possible price ratio in the protocol
int32 constant MIN_TICK = -88722835;

/// @notice The maximum tick value supported by the protocol
/// @dev Corresponds to the maximum possible price ratio in the protocol
int32 constant MAX_TICK = 88722835;

/// @notice The maximum tick magnitude (absolute value of MAX_TICK)
/// @dev Used for validation and bounds checking in tick-related calculations
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);

/// @notice The maximum allowed tick spacing for pools
/// @dev Defines the upper limit for tick spacing configuration in pool creation
uint32 constant MAX_TICK_SPACING = 698605;

/// @notice Special tick spacing value indicating full-range-only pools
/// @dev When a pool uses this tick spacing, only full-range positions are allowed
uint32 constant FULL_RANGE_ONLY_TICK_SPACING = 0;

/// @notice Address used to represent the native token (ETH) within the protocol
/// @dev Using address(0) allows the protocol to handle native ETH alongside ERC20 tokens
address constant NATIVE_TOKEN_ADDRESS = address(0);
