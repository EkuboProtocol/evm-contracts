// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BasePositions} from "./base/BasePositions.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {computeFee} from "./math/fee.sol";

/// @title Ekubo Protocol Positions
/// @author Moody Salem <moody@ekubo.org>
/// @notice Tracks liquidity positions in Ekubo Protocol as NFTs
/// @dev Manages liquidity positions, fee collection, and protocol fees
contract Positions is BasePositions {
    /// @notice Protocol fee rate for swaps (as a fraction of 2^64)
    uint64 public immutable SWAP_PROTOCOL_FEE_X64;

    /// @notice Denominator for withdrawal protocol fee calculation
    uint64 public immutable WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR;

    /// @notice Constructs the Positions contract
    /// @param core The core contract instance
    /// @param owner The owner of the contract (for access control)
    /// @param _swapProtocolFeeX64 Protocol fee rate for swaps
    /// @param _withdrawalProtocolFeeDenominator Denominator for withdrawal protocol fee
    constructor(ICore core, address owner, uint64 _swapProtocolFeeX64, uint64 _withdrawalProtocolFeeDenominator)
        BasePositions(core, owner)
    {
        SWAP_PROTOCOL_FEE_X64 = _swapProtocolFeeX64;
        WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR = _withdrawalProtocolFeeDenominator;
    }

    /// @notice Handles protocol fee collection during fee collection
    /// @dev Implements the abstract method from BasePositions
    /// @param amount0 The amount of token0 fees collected before protocol fee deduction
    /// @param amount1 The amount of token1 fees collected before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect
    /// @return protocolFee1 The amount of token1 protocol fees to collect
    function _computeSwapProtocolFees(PoolKey memory, uint128 amount0, uint128 amount1)
        internal
        view
        override
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        if (SWAP_PROTOCOL_FEE_X64 != 0) {
            protocolFee0 = computeFee(amount0, SWAP_PROTOCOL_FEE_X64);
            protocolFee1 = computeFee(amount1, SWAP_PROTOCOL_FEE_X64);
        }
    }

    /// @notice Handles protocol fee collection during liquidity withdrawal
    /// @dev Implements the abstract method from BasePositions
    /// @param poolKey The pool key for the position
    /// @param amount0 The amount of token0 being withdrawn before protocol fee deduction
    /// @param amount1 The amount of token1 being withdrawn before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect
    /// @return protocolFee1 The amount of token1 protocol fees to collect
    function _computeWithdrawalProtocolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1)
        internal
        view
        override
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        uint64 fee = poolKey.config.fee();
        if (fee != 0 && WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR != 0) {
            protocolFee0 = computeFee(amount0, fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);
            protocolFee1 = computeFee(amount1, fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);
        }
    }
}
