// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

import {IPositions} from "./interfaces/IPositions.sol";
import {IRevenueBuybacks} from "./interfaces/IRevenueBuybacks.sol";

/// @title Positions Owner
/// @author Moody Salem <moody@ekubo.org>
/// @notice Manages ownership of the Positions contract and facilitates revenue buybacks
/// @dev This contract owns the Positions contract and can transfer protocol revenue to buybacks contracts
contract PositionsOwner is Ownable, Multicallable {
    /// @notice The Positions contract that this contract owns
    /// @dev Protocol fees are collected from this contract
    IPositions public immutable POSITIONS;

    /// @notice Thrown when attempting to withdraw tokens that are not configured for buybacks
    /// @dev At least one of the tokens in a pair must be configured to allow withdrawal
    error RevenueTokenNotConfigured();

    /// @notice Constructs the PositionsOwner contract
    /// @param owner The address that will own this contract and have administrative privileges
    /// @param _positions The Positions contract instance that this contract will own
    constructor(address owner, IPositions _positions) {
        _initializeOwner(owner);
        POSITIONS = _positions;
    }

    /// @notice Transfers ownership of the Positions contract to a new owner
    /// @dev Only callable by the owner of this contract
    /// @param newOwner The address that will become the new owner of the Positions contract
    function transferPositionsOwnership(address newOwner) external onlyOwner {
        Ownable(address(POSITIONS)).transferOwnership(newOwner);
    }

    /// @notice Withdraws protocol fees and transfers them to a buybacks contract, then calls roll
    /// @dev At least one of the tokens must be configured for buybacks in the target contract
    /// @param buybacks The revenue buybacks contract to send tokens to and call roll on
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawAndRoll(IRevenueBuybacks buybacks, address token0, address token1) external {
        // Check if at least one token is configured for buybacks
        (, uint32 minOrderDuration0,,,,) = buybacks.states(token0);
        (, uint32 minOrderDuration1,,,,) = buybacks.states(token1);
        if (minOrderDuration0 == 0 && minOrderDuration1 == 0) {
            revert RevenueTokenNotConfigured();
        }

        // Get available protocol fees
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        // Withdraw fees to the buybacks contract if there are any
        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(buybacks));
        }

        // Call roll for both tokens (roll will handle tokens that aren't configured)
        if (minOrderDuration0 != 0) {
            buybacks.roll(token0);
        }
        if (minOrderDuration1 != 0) {
            buybacks.roll(token1);
        }
    }

    /// @notice Withdraws protocol fees and transfers them to a buybacks contract
    /// @dev Does not call roll - useful when you want to accumulate tokens before rolling
    /// At least one of the tokens must be configured for buybacks in the target contract
    /// @param buybacks The revenue buybacks contract to send tokens to
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawToContract(IRevenueBuybacks buybacks, address token0, address token1) external {
        // Check if at least one token is configured for buybacks
        (, uint32 minOrderDuration0,,,,) = buybacks.states(token0);
        (, uint32 minOrderDuration1,,,,) = buybacks.states(token1);
        if (minOrderDuration0 == 0 && minOrderDuration1 == 0) {
            revert RevenueTokenNotConfigured();
        }

        // Get available protocol fees
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        // Withdraw fees to the buybacks contract if there are any
        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(buybacks));
        }
    }

    /// @notice Calls roll on a buybacks contract for specific tokens
    /// @dev Can be called by anyone to trigger buyback order creation
    /// @param buybacks The revenue buybacks contract to call roll on
    /// @param token0 The first token to roll (if configured)
    /// @param token1 The second token to roll (if configured)
    function rollTokens(IRevenueBuybacks buybacks, address token0, address token1) external {
        // Call roll for both tokens (roll will handle tokens that aren't configured)
        (, uint32 minOrderDuration0,,,,) = buybacks.states(token0);
        (, uint32 minOrderDuration1,,,,) = buybacks.states(token1);
        if (minOrderDuration0 != 0) {
            buybacks.roll(token0);
        }
        if (minOrderDuration1 != 0) {
            buybacks.roll(token1);
        }
    }
}
