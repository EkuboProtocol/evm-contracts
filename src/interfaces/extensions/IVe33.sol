// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";
import {PoolId} from "../../types/poolId.sol";
import {PoolKey} from "../../types/poolKey.sol";
import {PositionId} from "../../types/positionId.sol";
import {StakeId} from "../../types/stakeId.sol";

// Forward call type for claiming LP reward-token emissions.
// Payload after call type: abi.encode(PoolKey poolKey, PositionId positionId).
uint256 constant VE33_CLAIM_REWARDS = uint256(keccak256("IVe33#VE33_CLAIM_REWARDS"));
// Forward call type for increasing a ve stake.
// Payload after call type: abi.encode(StakeId stakeId, uint128 amount).
uint256 constant VE33_STAKE = uint256(keccak256("IVe33#VE33_STAKE"));
// Forward call type for decreasing an expired ve stake.
// Payload after call type: abi.encode(StakeId stakeId).
uint256 constant VE33_UNSTAKE = uint256(keccak256("IVe33#VE33_UNSTAKE"));
// Forward call type for claiming voter pool fees.
// Payload after call type: abi.encode(StakeId stakeId, PoolKey poolKey).
uint256 constant VE33_CLAIM_POOL_FEES = uint256(keccak256("IVe33#VE33_CLAIM_POOL_FEES"));
// Forward call type for scheduling global emissions.
// Payload after call type: abi.encode(uint64 startTime, uint64 endTime, uint160 rewardRate).
uint256 constant VE33_SCHEDULE_EMISSIONS = uint256(keccak256("IVe33#VE33_SCHEDULE_EMISSIONS"));

// Maximum ve stake duration.
uint256 constant VE33_MAX_STAKE_DURATION = 4 * 365 days;

/// @title Ve33 Interface
/// @notice Interface for the Ekubo ve(3,3) pool extension.
interface IVe33 is IExposedStorage, IExtension, IForwardee {
    /// @notice Thrown when a swap attempts to bypass the forward-only swap path.
    error SwapMustHappenThroughForward();
    /// @notice Thrown when a pool key is not configured for this extension.
    error IncorrectPoolExtension();
    /// @notice Thrown when voting for a pool that has not been initialized in Core.
    error PoolNotInitialized();
    /// @notice Thrown when claiming voter fees for a pool the stake did not vote for.
    error PoolNotVoted();
    /// @notice Thrown when a Ve33 pool uses a nonzero Core fee.
    error FeeMustBeZero();
    /// @notice Thrown when a concentrated Ve33 pool tick spacing is not a power of four.
    error TickSpacingMustBePowerOfFour();
    /// @notice Thrown when emission schedule timestamps are invalid.
    error InvalidTimestamps();
    /// @notice Thrown when an emission schedule requires more backing than Ve33 can account.
    error EmissionFundingOverflow();
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

    /// @notice Accumulates global emissions into global emission growth.
    function accrueEmissions() external;

    /// @notice Accumulates global emissions into the pool reward-per-liquidity global value.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) external;

    /// @notice Returns the accumulated rewards per liquidity inside a concentrated range.
    /// @dev Mirrors Core's inside-growth getter for Ve33 LP rewards. Stableswap positions use global reward growth.
    /// @param poolId The ID of the pool to fetch the rewards per liquidity inside.
    /// @param tickLower Lower bound of the price range to get the snapshot.
    /// @param tickUpper Upper bound of the price range to get the snapshot.
    /// @return rewardsPerLiquidity Accumulated rewards per liquidity inside the bounds.
    function getPoolRewardsPerLiquidityInside(PoolId poolId, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint256 rewardsPerLiquidity);

    /// @notice Finds the next initialized global emission schedule time strictly after `fromTime`.
    /// @param fromTime Time after which to search.
    /// @return time Next initialized schedule time, or 0 if none found within the maximum valid range.
    /// @return delta Scheduled emission-rate delta at `time`, or 0 if none found.
    function nextEmissionRateChangeTime(uint256 fromTime) external view returns (uint64 time, int256 delta);
}
