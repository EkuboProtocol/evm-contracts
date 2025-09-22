// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

import {IPositions} from "./interfaces/IPositions.sol";
import {IRevenueBuybacks} from "./interfaces/IRevenueBuybacks.sol";

/// @title Positions Owner
/// @author Moody Salem <moody@ekubo.org>
/// @notice Manages ownership of the Positions contract and facilitates revenue buybacks
/// @dev This contract owns the Positions contract and can transfer protocol revenue to a trusted buybacks contract
contract PositionsOwner is Ownable, Multicallable {
    /// @notice The Positions contract that this contract owns
    /// @dev Protocol fees are collected from this contract
    IPositions public immutable POSITIONS;

    /// @notice The trusted revenue buybacks contract that receives protocol fees
    /// @dev Only this contract can receive protocol revenue from this positions owner
    IRevenueBuybacks public immutable BUYBACKS;

    /// @notice Thrown when attempting to withdraw tokens that are not configured for buybacks
    /// @dev At least one of the tokens in a pair must be configured to allow withdrawal
    error RevenueTokenNotConfigured();

    /// @notice Constructs the PositionsOwner contract
    /// @param owner The address that will own this contract and have administrative privileges
    /// @param _positions The Positions contract instance that this contract will own
    /// @param _buybacks The trusted revenue buybacks contract that will receive protocol fees
    constructor(address owner, IPositions _positions, IRevenueBuybacks _buybacks) {
        _initializeOwner(owner);
        POSITIONS = _positions;
        BUYBACKS = _buybacks;
    }

    /// @notice Transfers ownership of the Positions contract to a new owner
    /// @dev Only callable by the owner of this contract
    /// @param newOwner The address that will become the new owner of the Positions contract
    function transferPositionsOwnership(address newOwner) external onlyOwner {
        Ownable(address(POSITIONS)).transferOwnership(newOwner);
    }

    /// @notice Withdraws protocol fees and transfers them to the buybacks contract, then calls roll
    /// @dev At least one of the tokens must be configured for buybacks in the buybacks contract
    /// Can be called by anyone to trigger revenue buybacks
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawAndRoll(address token0, address token1) external {
        // Check if at least one token is configured for buybacks
        (, uint32 minOrderDuration0,,,,) = BUYBACKS.states(token0);
        (, uint32 minOrderDuration1,,,,) = BUYBACKS.states(token1);
        if (minOrderDuration0 == 0 && minOrderDuration1 == 0) {
            revert RevenueTokenNotConfigured();
        }

        // Get available protocol fees
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        // Withdraw fees to the buybacks contract if there are any
        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(BUYBACKS));
        }

        // Call roll for both tokens (roll will handle tokens that aren't configured)
        if (minOrderDuration0 != 0) {
            BUYBACKS.roll(token0);
        }
        if (minOrderDuration1 != 0) {
            BUYBACKS.roll(token1);
        }
    }

    /// @notice Withdraws protocol fees and transfers them to the buybacks contract
    /// @dev Does not call roll - useful when you want to accumulate tokens before rolling
    /// At least one of the tokens must be configured for buybacks in the buybacks contract
    /// Can be called by anyone to trigger revenue collection
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawToContract(address token0, address token1) external {
        // Check if at least one token is configured for buybacks
        (, uint32 minOrderDuration0,,,,) = BUYBACKS.states(token0);
        (, uint32 minOrderDuration1,,,,) = BUYBACKS.states(token1);
        if (minOrderDuration0 == 0 && minOrderDuration1 == 0) {
            revert RevenueTokenNotConfigured();
        }

        // Get available protocol fees
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        // Withdraw fees to the buybacks contract if there are any
        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(BUYBACKS));
        }
    }

    /// @notice Calls roll on the buybacks contract for specific tokens
    /// @dev Can be called by anyone to trigger buyback order creation
    /// @param token0 The first token to roll (if configured)
    /// @param token1 The second token to roll (if configured)
    function rollTokens(address token0, address token1) external {
        // Call roll for both tokens (roll will handle tokens that aren't configured)
        (, uint32 minOrderDuration0,,,,) = BUYBACKS.states(token0);
        (, uint32 minOrderDuration1,,,,) = BUYBACKS.states(token1);
        if (minOrderDuration0 != 0) {
            BUYBACKS.roll(token0);
        }
        if (minOrderDuration1 != 0) {
            BUYBACKS.roll(token1);
        }
    }
}
