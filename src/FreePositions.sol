// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {BasePositions} from "./base/BasePositions.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {computeFee} from "./math/fee.sol";

/// @title Ekubo Protocol Free Positions
/// @author Moody Salem <moody@ekubo.org>
/// @notice A positions implementation that does not charge a protocol fee
contract FreePositions is BasePositions {
    constructor(ICore core, address owner) BasePositions(core, owner) {}

    /// @inheritdoc BasePositions
    function _computeSwapProtocolFees(PoolKey memory, uint128, uint128)
        internal
        pure
        override
        returns (uint128, uint128)
    {
        return (0, 0);
    }

    /// @inheritdoc BasePositions
    function _computeWithdrawalProtocolFees(PoolKey memory, uint128, uint128)
        internal
        pure
        override
        returns (uint128, uint128)
    {
        return (0, 0);
    }
}
