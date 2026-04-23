// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IOrders} from "./interfaces/IOrders.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {RevenueBuybacks} from "./RevenueBuybacks.sol";

/// @title Positions Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Owns a Positions contract and routes its protocol fees into RevenueBuybacks
/// @dev Combines protocol fee ownership and buyback execution in a single governance-owned contract
contract PositionsRevenueBuybacks is RevenueBuybacks {
    /// @notice The Positions contract that this contract owns
    /// @dev Protocol fees are collected from this contract and sent directly here for buybacks
    IPositions public immutable POSITIONS;

    /// @param owner The address that will own this contract and have administrative privileges
    /// @param _positions The Positions contract instance that this contract will own
    /// @param _orders The Orders contract instance for creating TWAMM orders
    /// @param _buyToken The token that will be purchased with collected revenue
    constructor(address owner, IPositions _positions, IOrders _orders, address _buyToken)
        RevenueBuybacks(owner, _orders, _buyToken)
    {
        POSITIONS = _positions;
    }

    /// @notice Withdraws protocol fees and rolls them into buyback orders for both tokens
    /// @dev Can be called by anyone to trigger revenue buybacks for a token pair
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawAndRoll(address token0, address token1) external {
        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);

        assembly ("memory-safe") {
            // Leave 1 wei behind when possible to save gas on future protocol fee accrual.
            amount0 := sub(amount0, gt(amount0, 0))
            amount1 := sub(amount1, gt(amount1, 0))
        }

        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(this));

            this.roll(token0);
            this.roll(token1);
        }
    }
}
