// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IExtension} from "../ICore.sol";
import {IForwardee} from "../IFlashAccountant.sol";
import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";
import {PositionId} from "../../types/positionId.sol";

/// @title Single Token Rewards Extension Interface
/// @notice Streams a single reward token to pool liquidity positions.
/// @dev Reward additions and claims are executed via Core.forward.
interface ISingleTokenRewards is IExtension, IForwardee {
    /// @notice Emitted when rewards are added to a pool.
    /// @param poolId Identifier of the pool that is being rewarded.
    /// @param startTime The first second that rewards will be paid out.
    /// @param endTime The time at which rewards stop paying out.
    /// @param rewardRate Per-second reward rate as a fixed point 80.32 value.
    /// @param amount Amount of reward token funded.
    event PoolRewarded(PoolId poolId, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);

    /// @notice Emitted when rewards are donated immediately to pool liquidity.
    /// @param poolId Identifier of the pool.
    /// @param amount Amount of reward token donated.
    event RewardsDonated(PoolId poolId, uint128 amount);

    /// @notice Emitted when rewards are claimed for a position.
    /// @param poolId Identifier of the pool.
    /// @param owner Core position owner.
    /// @param positionId Position identifier.
    /// @param recipient Address that received rewards.
    /// @param amount Amount of reward token claimed.
    event RewardsClaimed(PoolId poolId, address owner, PositionId positionId, address recipient, uint256 amount);

    /// @notice Reverts when provided times are invalid.
    error InvalidTimestamps();
    /// @notice Reverts when we try to update state for a pool that is not initialized for this extension.
    error PoolNotInitialized();
    /// @notice Reverts when incentive rates exceed permitted bounds.
    error MaxRateDeltaPerTime();
    /// @notice Reverts when an amount cannot fit in Core saved balances.
    error RewardAmountOverflow();

    /// @notice Reward token distributed by this extension.
    function rewardToken() external view returns (address);

    /// @notice Accrues rewards for a pool to the current timestamp.
    /// @param poolKey The pool key to accrue.
    function maybeAccumulateRewards(PoolKey memory poolKey) external;
}
