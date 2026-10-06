// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

// Forward call types for ScheduledLaunch and its LockedLaunchLiquidity. A forwarded payload whose first word is
// none of these is decoded by ScheduledLaunch as the standard swap payload abi.encode(PoolKey, SwapParameters),
// whose first word is a token address and so never equals a hashed call type.

// ScheduledLaunch: creates a launch. Payload after call type: abi.encode(ScheduledLaunch.LaunchConfig config).
// Returns abi.encode(PoolKey key, address token). Supply is minted to Core and saved for the launch in the same
// forward, so the forwarding locker owes nothing.
// Derived as uint256(keccak256("IScheduledLaunch#LAUNCH_CREATE")).
uint256 constant LAUNCH_CREATE = 0x9e390bed22451d5619bc85817d652432391c746c99b257160e16704229a623e8;
// LockedLaunchLiquidity: adds counterpart assets to a migrated launch's locked principal.
// Payload after call type: abi.encode(PoolId launchId, uint128 amount0, uint128 amount1).
// Returns nothing. The forwarding locker owes amount0 and amount1.
// Derived as uint256(keccak256("IScheduledLaunch#LAUNCH_FUND")).
uint256 constant LAUNCH_FUND = 0x6fe1ab53aa6a14a578053ace205e2f14e25f052122e022acd6dff73c6b9f2869;
// Both contracts: releases the launch owner's fees to the forwarding locker, which must be the owner of record.
// ScheduledLaunch payload after call type: abi.encode(PoolKey key, address recipient).
// LockedLaunchLiquidity payload after call type: abi.encode(PoolId launchId, address recipient).
// Returns abi.encode(uint128 amount0, uint128 amount1), credited to the forwarding locker to withdraw.
// recipient is recorded in the claim event only.
// Derived as uint256(keccak256("IScheduledLaunch#LAUNCH_CLAIM_FEES")).
uint256 constant LAUNCH_CLAIM_FEES = 0x4b9a7226519dba29c1ed0e986d4c1d489c4807ddbb250442b1df4bcafd2a40c4;
