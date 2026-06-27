// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseVe33Positions} from "./base/BaseVe33Positions.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {computeFee} from "./math/fee.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice ERC721 position manager for Ve33 liquidity positions with a protocol fee on claimed rewards.
contract Ve33Positions is BaseVe33Positions {
    /// @notice Protocol fee rate for claimed rewards, as a fraction of 2^64.
    uint64 public immutable REWARD_PROTOCOL_FEE_X64;

    /// @notice Creates the Ve33 position NFT manager.
    /// @param core Ekubo Core contract used for locks and position updates.
    /// @param ve33 Ve33 extension whose pools are supported.
    /// @param owner Owner allowed to set collection metadata and withdraw protocol fees.
    /// @param rewardProtocolFeeX64 Protocol fee rate for claimed rewards, as a fraction of 2^64.
    constructor(ICore core, Ve33 ve33, address owner, uint64 rewardProtocolFeeX64)
        BaseVe33Positions(core, ve33, owner)
    {
        REWARD_PROTOCOL_FEE_X64 = rewardProtocolFeeX64;
    }

    /// @inheritdoc BaseVe33Positions
    function _computeClaimRewardsProtocolFee(PoolKey memory, uint128 amount)
        internal
        view
        override
        returns (uint128 protocolFee)
    {
        if (REWARD_PROTOCOL_FEE_X64 != 0) protocolFee = computeFee(amount, REWARD_PROTOCOL_FEE_X64);
    }
}
