// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Unique identifier for a TWAMM order
/// @dev Wraps bytes32 to provide type safety for order identifiers
type OrderId is bytes32;
