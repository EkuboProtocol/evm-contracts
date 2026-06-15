// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";

uint256 constant SINGLE_TOKEN_REWARDS_ADD_REWARDS = 0;
uint256 constant SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT = 1;
uint256 constant SINGLE_TOKEN_REWARDS_DONATE_REWARDS = 2;

/// @title Single Token Rewards Library
/// @notice Helper methods for interacting with the SingleTokenRewards extension via Core.forward.
library SingleTokenRewardsLib {
    /// @notice Adds rewards to a pool via Core.forward.
    /// @param core The core contract.
    /// @param poolKey The pool key using the SingleTokenRewards extension.
    /// @param startTime First second rewards are paid.
    /// @param endTime Time at which rewards stop paying.
    /// @param rewardRate Per-second reward rate as a fixed point 80.32 value.
    /// @return amount Amount of reward token funded.
    function addRewards(ICore core, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        internal
        returns (uint224 amount)
    {
        amount = abi.decode(
            core.forward(
                poolKey.config.extension(),
                abi.encode(SINGLE_TOKEN_REWARDS_ADD_REWARDS, poolKey, startTime, endTime, rewardRate)
            ),
            (uint224)
        );
    }

    /// @notice Donates rewards immediately to active pool liquidity via Core.forward.
    /// @param core The core contract.
    /// @param poolKey The pool key using the SingleTokenRewards extension.
    /// @param amount Amount of reward token to donate.
    /// @return donatedAmount Amount of reward token donated.
    function donateRewards(ICore core, PoolKey memory poolKey, uint128 amount)
        internal
        returns (uint128 donatedAmount)
    {
        donatedAmount = abi.decode(
            core.forward(poolKey.config.extension(), abi.encode(SINGLE_TOKEN_REWARDS_DONATE_REWARDS, poolKey, amount)),
            (uint128)
        );
    }

    /// @notice Claims rewards for the current locker-owned position to a recipient via Core.forward.
    /// @param core The core contract.
    /// @param poolKey The pool key using the SingleTokenRewards extension.
    /// @param positionId Position identifier.
    /// @param recipient Address that receives rewards.
    /// @return amount Amount claimed.
    function claimRewards(ICore core, PoolKey memory poolKey, PositionId positionId, address recipient)
        internal
        returns (uint256 amount)
    {
        amount = abi.decode(
            core.forward(
                poolKey.config.extension(),
                abi.encode(SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT, poolKey, positionId, recipient)
            ),
            (uint256)
        );
    }
}
