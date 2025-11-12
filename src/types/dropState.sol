// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

using {funded, claimed, setFunded, setClaimed, getRemaining} for DropState global;

/// @notice Represents the state of a drop with funded and claimed amounts
/// @dev Packed into a single bytes32 slot: funded (128 bits) + claimed (128 bits)
type DropState is bytes32;

/// @notice Gets the funded amount from a drop state
/// @param state The drop state
/// @return amount The funded amount
function funded(DropState state) pure returns (uint128 amount) {
    assembly ("memory-safe") {
        amount := shr(128, state)
    }
}

/// @notice Gets the claimed amount from a drop state
/// @param state The drop state
/// @return amount The claimed amount
function claimed(DropState state) pure returns (uint128 amount) {
    assembly ("memory-safe") {
        amount := and(state, 0xffffffffffffffffffffffffffffffff)
    }
}

/// @notice Sets the funded amount in a drop state
/// @param state The drop state
/// @param amount The funded amount to set
/// @return newState The updated drop state
function setFunded(DropState state, uint128 amount) pure returns (DropState newState) {
    assembly ("memory-safe") {
        newState := or(and(state, 0xffffffffffffffffffffffffffffffff), shl(128, amount))
    }
}

/// @notice Sets the claimed amount in a drop state
/// @param state The drop state
/// @param amount The claimed amount to set
/// @return newState The updated drop state
function setClaimed(DropState state, uint128 amount) pure returns (DropState newState) {
    assembly ("memory-safe") {
        newState := or(and(state, 0xffffffffffffffffffffffffffffffff00000000000000000000000000000000), amount)
    }
}

/// @notice Gets the remaining amount (funded - claimed) from a drop state
/// @param state The drop state
/// @return remaining The remaining amount available for claims
function getRemaining(DropState state) pure returns (uint128 remaining) {
    unchecked {
        remaining = state.funded() - state.claimed();
    }
}
