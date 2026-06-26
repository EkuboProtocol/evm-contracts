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
    /// @notice Thrown when a swap attempts to bypass the forward-only swap path.
    error SwapMustHappenThroughForward();
    /// @notice Thrown when a pool key is not configured for this extension.
    error IncorrectPoolExtension();
    /// @notice Thrown when claiming voter fees for a pool the stake did not vote for.
    error PoolNotVoted();
    /// @notice Thrown when a Ve33 pool uses a nonzero Core fee.
    error FeeMustBeZero();
    /// @notice Thrown when a concentrated Ve33 pool tick spacing is not a power of four.
    error TickSpacingMustBePowerOfFour();
    /// @notice Thrown when emission schedule timestamps are invalid.
    error InvalidTimestamps();
    /// @notice Thrown when an emission-rate delta exceeds the allowed bound.
    error MaxRateDeltaPerTime();
    /// @notice Thrown when a new stake end timestamp is not in the future.
    error StakeEndNotInFuture();
    /// @notice Thrown when a new stake end timestamp is farther than the max stake duration.
    error StakeDurationTooLong();
    /// @notice Thrown when unstaking before a stake has expired.
    error StakeNotExpired();
    /// @notice Thrown when moving more stake than the source stake contains.
    error StakeAmountExceedsBalance();
    /// @notice Thrown when splitting a stake into the same stake id.
    error CannotSplitStakeIntoItself();
    /// @notice Thrown when splitting an amount that would leave no source stake.
    error SplitAmountMustBeLessThanStakeAmount();
    /// @notice Thrown when moving stake to a stake id that ends before or at the source stake id.
    error MoveStakeToEarlierEndTime();

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
