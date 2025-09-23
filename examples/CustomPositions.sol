// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {BasePositions} from "../src/base/BasePositions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {computeFee} from "../src/math/fee.sol";

/// @title Custom Positions Contract Example
/// @notice Example implementation of BasePositions with custom protocol fee collection logic
/// @dev This demonstrates how to create alternative fee collection strategies
contract CustomPositions is BasePositions {
    /// @notice Fixed protocol fee rate (1% = 1844674407370955161)
    uint64 public constant FIXED_PROTOCOL_FEE_X64 = 184467440737095516; // 1% as fraction of 2^64

    /// @notice Whether protocol fees are enabled
    bool public protocolFeesEnabled;

    /// @notice Owner can toggle protocol fees on/off
    modifier onlyOwnerCanToggleFees() {
        require(msg.sender == owner(), "Only owner can toggle fees");
        _;
    }

    /// @notice Constructs the CustomPositions contract
    /// @param core The core contract instance
    /// @param owner The owner of the contract (for access control)
    constructor(ICore core, address owner) BasePositions(core, owner) {
        protocolFeesEnabled = true;
    }

    /// @notice Toggle protocol fee collection on/off
    /// @param enabled Whether to enable protocol fees
    function setProtocolFeesEnabled(bool enabled) external onlyOwnerCanToggleFees {
        protocolFeesEnabled = enabled;
    }

    /// @notice Custom swap protocol fee collection - fixed 1% rate when enabled
    /// @dev Implements the abstract method from BasePositions
    /// @param amount0 The amount of token0 fees collected before protocol fee deduction
    /// @param amount1 The amount of token1 fees collected before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect
    /// @return protocolFee1 The amount of token1 protocol fees to collect
    function _collectSwapProtocolFees(PoolKey memory, uint128 amount0, uint128 amount1)
        internal
        view
        override
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        if (protocolFeesEnabled) {
            protocolFee0 = computeFee(amount0, FIXED_PROTOCOL_FEE_X64);
            protocolFee1 = computeFee(amount1, FIXED_PROTOCOL_FEE_X64);
        }
        // If disabled, returns (0, 0) by default
    }

    /// @notice Custom withdrawal protocol fee collection - no withdrawal fees
    /// @dev Implements the abstract method from BasePositions
    /// @param amount0 The amount of token0 being withdrawn before protocol fee deduction
    /// @param amount1 The amount of token1 being withdrawn before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect (always 0)
    /// @return protocolFee1 The amount of token1 protocol fees to collect (always 0)
    function _collectWithdrawalProtocolFees(PoolKey memory, uint128 amount0, uint128 amount1)
        internal
        pure
        override
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        // This custom implementation doesn't charge withdrawal fees
        // Both return values are 0 by default
        (amount0, amount1); // Silence unused parameter warnings
    }
}
