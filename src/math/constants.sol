// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

// Protocol Constants
// Contains all constant values used throughout the Ekubo Protocol
// These constants define the boundaries and special values for the protocol's operation

// The minimum tick value supported by the protocol
// Corresponds to the minimum possible price ratio in the protocol
int32 constant MIN_TICK = -88722835;

// The maximum tick value supported by the protocol
// Corresponds to the maximum possible price ratio in the protocol
int32 constant MAX_TICK = 88722835;

// The maximum tick magnitude (absolute value of MAX_TICK)
// Used for validation and bounds checking in tick-related calculations
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);

// The maximum allowed tick spacing for pools
// Defines the upper limit for tick spacing configuration in pool creation
uint32 constant MAX_TICK_SPACING = 698605;

// Special tick spacing value indicating full-range-only pools
// When a pool uses this tick spacing, only full-range positions are allowed
uint32 constant FULL_RANGE_ONLY_TICK_SPACING = 0;

// Stableswap pool type flag (bit 31 of tick spacing field)
// When set, the tick spacing field encodes stableswap parameters instead
uint32 constant STABLESWAP_POOL_TYPE_FLAG = 0x80000000;

// Mask for extracting the center tick from stableswap config (bits 0-27)
uint32 constant STABLESWAP_CENTER_TICK_MASK = 0x0FFFFFFF;

// Mask for extracting the amplification factor from stableswap config (bits 28-30)
uint32 constant STABLESWAP_AMPLIFICATION_MASK = 0x70000000;

// Bit shift for amplification factor in stableswap config
uint32 constant STABLESWAP_AMPLIFICATION_SHIFT = 28;

// Address used to represent the native token (ETH) within the protocol
// Using address(0) allows the protocol to handle native ETH alongside ERC20 tokens
address constant NATIVE_TOKEN_ADDRESS = address(0);
