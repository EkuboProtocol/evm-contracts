// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

import {IPositions} from "./interfaces/IPositions.sol";
import {IRevenueBuybacks} from "./interfaces/IRevenueBuybacks.sol";
import {RevenueBuybacksLib} from "./libraries/RevenueBuybacksLib.sol";
import {BuybacksState} from "./types/buybacksState.sol";

/// @title Positions Owner
/// @author Moody Salem <moody@ekubo.org>
/// @notice Manages ownership of the Positions contract and facilitates buybacks with the collected revenue
/// @dev This contract owns the Positions contract and transfers protocol revenue to a trusted buybacks contract
contract PositionsOwner is Ownable, Multicallable {
    using RevenueBuybacksLib for *;

    /// @notice The Positions contract that this contract owns
    /// @dev Protocol fees are collected from this contract
    IPositions public immutable POSITIONS;

    /// @notice The trusted revenue buybacks contract that receives protocol fees
    /// @dev Only this contract can receive protocol revenue from this positions owner
    IRevenueBuybacks public immutable BUYBACKS;

    /// @notice Thrown when attempting to withdraw protocol revenue for tokens that are not configured for buybacks
    /// @dev Both tokens in a pair must be configured to allow withdrawal
    error RevenueTokenNotConfigured();

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

    /// @notice Withdraws protocol fees and transfers them to the buybacks contract, then calls roll for both tokens. Can be called by anyone to trigger revenue buybacks
    /// @dev Both tokens must be configured for buybacks in the buybacks contract
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawAndRoll(address token0, address token1) external {
        // Check if at least one token is configured for buybacks
        (BuybacksState s0, BuybacksState s1) = BUYBACKS.state(token0, token1);
        if (s0.minOrderDuration() == 0 || s1.minOrderDuration() == 0) {
            revert RevenueTokenNotConfigured();
        }

        // Get available protocol fees
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        // Withdraw fees to the buybacks contract if there are any
        if (amount0 > 1 || amount1 > 1) {
            POSITIONS.withdrawProtocolFees(
                token0,
                token1,
                uint128(FixedPointMathLib.zeroFloorSub(amount0, 1)),
                uint128(FixedPointMathLib.zeroFloorSub(amount1, 1)),
                address(BUYBACKS)
            );
        }

        // Call roll for both tokens
        BUYBACKS.roll(token0);
        BUYBACKS.roll(token1);
    }
}
