// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

int32 constant MIN_TICK = -88722835;
int32 constant MAX_TICK = 88722835;
uint32 constant MAX_TICK_MAGNITUDE = uint32(MAX_TICK);
uint32 constant MAX_TICK_SPACING = 698605;

uint32 constant FULL_RANGE_ONLY_TICK_SPACING = 0;

uint256 constant MIN_SQRT_RATIO = 18447191164202170526;
uint256 constant MAX_SQRT_RATIO = 6276949602062853172742588666638147158083741740262337144812;

// We use this address to represent the native token within the protocol
address constant NATIVE_TOKEN_ADDRESS = address(0);
