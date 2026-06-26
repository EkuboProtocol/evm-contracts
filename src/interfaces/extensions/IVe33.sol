// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";
import {PoolId} from "../../types/poolId.sol";
import {PoolKey} from "../../types/poolKey.sol";
import {PositionId} from "../../types/positionId.sol";
import {StakeId} from "../../types/stakeId.sol";

/// @title Ve33 Interface
/// @notice Interface for the Ekubo ve(3,3) pool extension.
interface IVe33 is IExposedStorage, IExtension, IForwardee {
    /// @notice Emitted when a stake amount changes.
    /// @dev Positive deltas add stake, negative deltas remove stake.
    event StakeChanged(address owner, StakeId stakeId, int256 delta);

    /// @notice Emitted after a stake's applied vote weight changes.
    /// @param swapFee Effective pool swap fee after applying the weight change.
    event VoteWeightApplied(address owner, StakeId stakeId, PoolId poolId, uint128 weight, uint64 swapFee);

    /// @notice Emitted when a swap accounts fees to voters.
    event PoolFeesAccounted(PoolId poolId, uint128 amount0, uint128 amount1);

    /// @notice Emitted when accrued voter fees are claimed for a stake.
    event PoolFeesClaimed(PoolId poolId, address owner, StakeId stakeId, uint128 amount0, uint128 amount1);

    /// @notice Emitted when global emissions are scheduled.
    event EmissionsScheduled(address funder, uint64 startTime, uint64 endTime, uint160 rewardRate, uint128 amount);

    /// @notice Emitted when a pool accrues its share of global emissions to LP rewards.
    event PoolEmissionsAccrued(PoolId poolId, uint256 amount);

    /// @notice Emitted when an LP position claims reward tokens.
    event RewardsClaimed(PoolId poolId, address owner, PositionId positionId, uint256 amount);

    /// @notice Token used for ve staking, global emissions, and LP rewards.
    function stakeToken() external view returns (address);

    /// @notice Replaces the vote for a stake owned by the caller.
    /// @param stakeId Stake whose votes are being updated.
    /// @param poolKey Pool receiving the stake's full active voting power.
    /// @param swapFee Explicit swap fee vote for the pool.
    function vote(StakeId stakeId, PoolKey calldata poolKey, uint64 swapFee) external;

    /// @notice Clears the active vote for a stake owned by the caller.
    /// @param stakeId Stake whose vote is cleared.
    function clearVote(StakeId stakeId) external;

    /// @notice Moves stake between two stake keys owned by the caller.
    /// @param fromStakeId Source stake id.
    /// @param toStakeId Destination stake id.
    /// @param amount Amount of stake to move.
    /// @return nextAmount Destination stake amount after the move.
    function moveStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount) external returns (uint128 nextAmount);

    /// @notice Splits stake into a new stake key owned by the caller while preserving the source vote.
    /// @param fromStakeId Source stake id.
    /// @param toStakeId Destination stake id.
    /// @param amount Amount of stake to split into the destination key.
    /// @return nextAmount Destination stake amount after the split.
    function splitStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount) external returns (uint128 nextAmount);

    /// @notice Accumulates global emissions into global emission growth.
    function accrueEmissions() external;

    /// @notice Accumulates global emissions into the pool reward-per-liquidity global value.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) external;
}
