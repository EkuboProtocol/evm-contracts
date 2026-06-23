// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {isPowerOfFour} from "../math/isPowerOfFour.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
import {capFee} from "../math/tickSpacingFee.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "../math/timeBitmap.sol";
import {Bitmap} from "../types/bitmap.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {StakeId} from "../types/stakeId.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {Ve33RewardPoolState, createVe33RewardPoolState} from "../types/ve33RewardPoolState.sol";

// Forward call type for extension-mediated swaps.
uint256 constant VE33_SWAP = 0;
// Forward call type for claiming LP reward-token emissions.
uint256 constant VE33_CLAIM_REWARDS = 1;
// Forward call type for immediately donating reward tokens to in-range LP liquidity.
uint256 constant VE33_DONATE_REWARDS = 2;
// Forward call type for scheduling reward-token emissions.
uint256 constant VE33_SCHEDULE_REWARDS = 3;
// Forward call type for increasing a ve stake.
uint256 constant VE33_STAKE = 4;
// Forward call type for decreasing an expired ve stake.
uint256 constant VE33_UNSTAKE = 5;
// Forward call type for moving stake to a different stake id.
uint256 constant VE33_MOVE_STAKE = 6;
// Forward call type for claiming voter pool fees.
uint256 constant VE33_CLAIM_POOL_FEES = 7;
// Forward call type for scheduling global emissions.
uint256 constant VE33_SCHEDULE_EMISSIONS = 8;

// Maximum absolute scheduled reward-rate delta allowed at one valid time.
uint256 constant VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint224).max / MAX_NUM_VALID_TIMES;
// Maximum ve stake duration.
uint256 constant VE33_MAX_STAKE_DURATION = 4 * 365 days;

/// @notice Returns the Core hooks enabled by `Ve33`.
function ve33CallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: true,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @title Ve33
/// @notice Forward-only ve(3,3) pool extension with dynamic voter fees and single-token LP rewards.
/// @dev Pools using this extension must have zero Core pool fees. Swap fees are accounted by the extension and
/// distributed to ve stakers, while LPs earn the immutable `stakeToken` as rewards.
contract Ve33 is BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;
    /// @notice Duration of each per-pool emission stream.
    uint256 public constant EMISSION_DURATION = 7 days;
    /// @notice Maximum ve stake duration.
    uint256 public constant MAX_STAKE_DURATION = VE33_MAX_STAKE_DURATION;

    /// @notice Token used for ve staking, global emissions, and LP rewards.
    address public immutable stakeToken;

    /// @notice Vote, fee, and emission allocation state for one pool.
    /// @param feeGrowth0X128 Accumulated token0 fees per unit of vote weight.
    /// @param feeGrowth1X128 Accumulated token1 fees per unit of vote weight.
    /// @param emissionGrowthGlobalX128Snapshot Snapshot of global emission growth per unit of vote weight.
    /// @param feeWeightSum Sum of `weight * votedFee`, used to compute the weighted swap fee.
    /// @param weight Current active vote weight assigned to the pool.
    struct PoolVoteState {
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 emissionGrowthGlobalX128Snapshot;
        uint192 feeWeightSum;
        uint128 weight;
    }

    /// @notice Per-stake accounting for one voted pool.
    /// @param weight Active vote weight from the stake to the pool.
    /// @param swapFee Fee selected by the stake for this pool.
    /// @param feeGrowth0X128 Snapshot of pool token0 fee growth.
    /// @param feeGrowth1X128 Snapshot of pool token1 fee growth.
    struct VePoolPosition {
        uint128 weight;
        uint64 swapFee;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    }

    /// @notice Stake amounts by `(owner, stakeId)`.
    mapping(address => mapping(StakeId => uint128)) internal stakeAmounts;
    /// @notice Pools currently voted on by each stake id.
    mapping(address => mapping(StakeId => PoolId[])) internal votedPools;
    /// @notice Per-stake, per-pool vote and fee snapshots.
    mapping(address => mapping(StakeId => mapping(PoolId => VePoolPosition))) internal vePoolPositions;
    /// @notice Aggregated voting and fee state for each pool.
    mapping(PoolId => PoolVoteState) internal poolVoteStates;
    /// @notice Canonical pool keys for initialized Ve33 pools, used to accrue rewards during vote updates.
    mapping(PoolId => PoolKey) internal storedPoolKeys;

    /// @notice Packed reward-stream state for each pool.
    mapping(PoolId => Ve33RewardPoolState) internal poolRewardState;
    /// @notice Global reward-token growth per unit of in-range liquidity for each pool.
    mapping(PoolId => uint256) internal rewardsGlobalPerLiquidity;
    /// @notice Reward growth outside each initialized tick, used to compute in-range rewards.
    mapping(PoolId => mapping(int32 => uint256)) internal tickRewardsOutsidePerLiquidity;
    /// @notice Per-position reward growth snapshot.
    mapping(PoolId => mapping(address => mapping(PositionId => uint256))) internal positionRewardsSnapshotPerLiquidity;
    /// @notice Bitmap of initialized reward schedule times for each pool.
    mapping(PoolId => mapping(uint256 => uint256)) private initializedTimeBitmap;
    /// @notice Scheduled reward-rate deltas at valid times for each pool.
    mapping(PoolId => mapping(uint256 => int256)) internal rewardRateDeltaAtTime;

    /// @notice Total active ve vote weight across all pools.
    uint128 internal totalVoteWeight;

    /// @notice Funded emissions not yet paid into pool reward schedules.
    uint256 internal emissionReserve;
    /// @notice Accumulated global emission growth per unit of active vote weight.
    uint256 internal emissionGrowthGlobalX128;
    /// @notice Current global Q32 emission rate.
    uint224 internal emissionRate;
    /// @notice Last timestamp when global emissions were accrued.
    uint64 internal emissionsLastAccrued;
    /// @notice Bitmap of valid global emission-rate change times.
    mapping(uint256 => uint256) private emissionInitializedTimeBitmap;
    /// @notice Global emission-rate deltas at each initialized time.
    mapping(uint64 => int256) internal emissionRateDeltaAtTime;

    /// @notice Emitted when stake is added.
    event StakeIncreased(address owner, StakeId stakeId, uint128 amount);
    /// @notice Emitted when expired stake is removed.
    event StakeDecreased(address owner, StakeId stakeId, uint128 amount);
    /// @notice Emitted when stake is moved between stake keys.
    event StakeMoved(address owner, StakeId fromStakeId, StakeId toStakeId);
    /// @notice Emitted after a stake's votes are updated.
    event Voted(address owner, StakeId stakeId);
    /// @notice Emitted when a swap accounts fees to voters.
    event PoolFeesAccounted(PoolId poolId, uint128 amount0, uint128 amount1);
    /// @notice Emitted when accrued voter fees are claimed for a stake.
    event PoolFeesClaimed(
        PoolId poolId, address owner, StakeId stakeId, address recipient, uint128 amount0, uint128 amount1
    );
    /// @notice Emitted when a stake's active votes are reduced to current decayed voting power.
    event StakePoked(address owner, StakeId stakeId, uint256 previousWeight, uint256 nextWeight);
    /// @notice Emitted when global emissions are scheduled.
    event EmissionsScheduled(address funder, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    /// @notice Emitted when a pool accrues its share of global emissions to LP rewards.
    event PoolEmissionsAccrued(PoolId poolId, uint256 amount);
    /// @notice Emitted when a pool reward stream is scheduled.
    event PoolRewardsScheduled(PoolId poolId, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    /// @notice Emitted when an LP position claims reward tokens.
    event RewardsClaimed(PoolId poolId, address owner, PositionId positionId, address recipient, uint256 amount);
    /// @notice Emitted when reward tokens are donated directly to current pool liquidity.
    event RewardsDonated(PoolId poolId, uint128 amount);

    /// @notice Thrown when a pool is initialized with a nonzero Core fee.
    error ZeroConfigFeeOnly();
    /// @notice Thrown when a swap attempts to bypass the forward-only swap path.
    error SwapMustHappenThroughForward();
    /// @notice Thrown when a vote payload or target pool is invalid.
    error InvalidVote();
    /// @notice Thrown when a concentrated pool tick spacing is not a power of four.
    error InvalidTickSpacing();
    /// @notice Thrown when a global emission schedule amount is zero.
    error EmissionAmountTooSmall();
    /// @notice Thrown when reward schedule timestamps are invalid.
    error InvalidTimestamps();
    /// @notice Thrown when a reward amount cannot fit in the supported token accounting width.
    error RewardAmountOverflow();
    /// @notice Thrown when a reward-rate delta exceeds the allowed bound.
    error MaxRateDeltaPerTime();
    /// @notice Thrown when reward accounting is requested for a pool not initialized for this extension.
    error PoolNotInitialized();
    /// @notice Thrown when a stake amount or timestamp is invalid.
    error InvalidStake();

    /// @notice Initializes the extension with Core and the immutable reward/stake token.
    /// @param core Ekubo Core contract.
    /// @param _stakeToken Token used for ve stakes and LP rewards.
    constructor(ICore core, address _stakeToken) BaseExtension(core) BaseForwardee(core) {
        stakeToken = _stakeToken;
        emissionsLastAccrued = uint64(block.timestamp);
    }

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return ve33CallPoints();
    }

    /// @notice Validates extension-specific pool configuration before Core initializes a new pool.
    /// @dev Pools must use zero Core fee because the active fee is stored in `poolVoteStates`.
    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension) onlyCore {
        if (poolKey.config.fee() != 0) revert ZeroConfigFeeOnly();

        if (poolKey.config.isConcentrated()) {
            uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
            if (!isPowerOfFour(tickSpacing)) revert InvalidTickSpacing();
        }
    }

    /// @notice Initializes extension reward state after Core initializes a new pool.
    function afterInitializePool(address, PoolKey memory poolKey, int32, SqrtRatio)
        external
        override(BaseExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        storedPoolKeys[poolId] = poolKey;
        poolRewardState[poolId] = createVe33RewardPoolState(uint32(block.timestamp), 0);
        poolVoteStates[poolId].emissionGrowthGlobalX128Snapshot = emissionGrowthGlobalX128;
    }

    /// @notice Rejects direct Core swaps.
    /// @dev Swaps must be executed through `forward` with `VE33_SWAP` so extension fees can be accounted.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension) {
        revert SwapMustHappenThroughForward();
    }

    /// @notice Snapshots LP reward accounting before a position's liquidity changes.
    /// @dev Keeps range-aware reward accounting synchronized with Core position updates.
    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        override(BaseExtension)
        onlyCore
    {
        _beforeUpdatePosition(locker.addr(), poolKey, positionId, liquidityDelta);
    }

    /// @notice Computes the current voting power for a stake.
    /// @dev Voting power decays linearly to zero at `stakeId.endTime()`.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Canonical stake id.
    /// @return power Current voting power.
    function _votingPower(address owner, StakeId stakeId) private view returns (uint128 power) {
        uint64 endTime = stakeId.endTime();
        if (block.timestamp >= endTime) return 0;

        unchecked {
            power = uint128((uint256(stakeAmounts[owner][stakeId]) * (endTime - block.timestamp)) / MAX_STAKE_DURATION);
        }
    }

    /// @notice Replaces the votes for a stake owned by the caller.
    /// @dev `swapFees` are capped to the protocol maximum.
    /// @param stakeId Stake whose votes are being updated.
    /// @param poolKeys Pools to vote on.
    /// @param weights Relative weights assigned to each pool.
    /// @param swapFees Explicit swap fee vote for each pool.
    function vote(StakeId stakeId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] calldata swapFees)
        external
    {
        _vote(msg.sender, stakeId, poolKeys, weights, swapFees);
    }

    /// @notice Permissionlessly refreshes a stake's active votes to its current decayed voting power.
    /// @dev Accrues reward and voter-fee accounting before reducing weights. Expired stakes are cleared.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake whose active votes are refreshed.
    /// @return previousWeight Total active vote weight before the poke.
    /// @return nextWeight Total active vote weight after the poke.
    function poke(address owner, StakeId stakeId) external returns (uint256 previousWeight, uint256 nextWeight) {
        (previousWeight, nextWeight) = _pokeVotes(owner, stakeId, _votingPower(owner, stakeId));
        emit StakePoked(owner, stakeId, previousWeight, nextWeight);
    }

    /// @notice Accumulates scheduled LP rewards into the pool reward-per-liquidity global value.
    /// @dev If the pool has no active in-range liquidity, accrued rewards are not assigned to LPs.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            Ve33RewardPoolState state = poolRewardState[poolId];

            if (state.lastAccumulated() == 0) {
                if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
                state = createVe33RewardPoolState(uint32(block.timestamp), 0);
                poolRewardState[poolId] = state;
            }

            _accrueEmissions();

            if (uint32(block.timestamp) == state.lastAccumulated()) return;

            uint256 lastAccumulated = state.realLastAccumulated();
            uint256 time = lastAccumulated;
            uint256 rewardRate = state.rewardRate();
            uint256 rewardsAccrued;

            for (uint256 eventTime; time != block.timestamp; time = eventTime) {
                bool hasEvent;
                (eventTime, hasEvent) = _searchForNextInitializedTime(poolId, lastAccumulated, time, block.timestamp);

                rewardsAccrued += (rewardRate * (eventTime - time)) >> 32;

                if (hasEvent) {
                    int256 rateDelta = rewardRateDeltaAtTime[poolId][eventTime];
                    rewardRate = _addRewardRate(rewardRate, rateDelta);

                    delete rewardRateDeltaAtTime[poolId][eventTime];
                    _flipTime(poolId, eventTime);
                }
            }

            uint128 liquidity = _activeRewardLiquidity(poolKey, CORE.poolState(poolId));
            uint256 emissionRewardsAccrued = _poolEmissionRewardsAccrued(poolId);

            if (emissionRewardsAccrued != 0) {
                if (emissionRewardsAccrued > emissionReserve) emissionRewardsAccrued = emissionReserve;
                emissionReserve -= emissionRewardsAccrued;

                emit PoolEmissionsAccrued(poolId, emissionRewardsAccrued);
            }

            if (liquidity != 0) {
                uint256 rewardsForLiquidity = rewardsAccrued + emissionRewardsAccrued;
                if (rewardsForLiquidity > type(uint128).max) revert RewardAmountOverflow();
                if (rewardsForLiquidity != 0) {
                    rewardsGlobalPerLiquidity[poolId] += (rewardsForLiquidity << 128) / liquidity;
                }
            }

            poolRewardState[poolId] = createVe33RewardPoolState(uint32(block.timestamp), uint224(rewardRate));
        }
    }

    /// @notice Handles extension forward calls from Core.
    /// @dev The original locker becomes the LP owner or stake owner depending on the call type.
    /// @param original Locker that initiated the Core forward call.
    /// @param data ABI-encoded call type and payload.
    /// @return result ABI-encoded result for the selected forward call.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == VE33_SWAP) {
            (, PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (uint256, PoolKey, SwapParameters));
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = _swap(poolKey, params);
            result = abi.encode(balanceUpdate, stateAfter);
        } else if (callType == VE33_CLAIM_REWARDS) {
            (, PoolKey memory poolKey, PositionId positionId, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));
            result = abi.encode(_claimRewards(poolKey, original.addr(), positionId, recipient));
        } else if (callType == VE33_DONATE_REWARDS) {
            (, PoolKey memory poolKey, uint128 amount) = abi.decode(data, (uint256, PoolKey, uint128));
            result = abi.encode(_donateRewards(poolKey, amount));
        } else if (callType == VE33_SCHEDULE_REWARDS) {
            (, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, PoolKey, uint64, uint64, uint224));
            result = abi.encode(_scheduleRewards(poolKey, startTime, endTime, rewardRate));
        } else if (callType == VE33_STAKE) {
            (, StakeId stakeId, uint128 amount) = abi.decode(data, (uint256, StakeId, uint128));
            result = abi.encode(_stake(original.addr(), stakeId, amount));
        } else if (callType == VE33_UNSTAKE) {
            (, StakeId stakeId) = abi.decode(data, (uint256, StakeId));
            result = abi.encode(_unstake(original.addr(), stakeId));
        } else if (callType == VE33_MOVE_STAKE) {
            (, StakeId fromStakeId, StakeId toStakeId, uint128 amount) =
                abi.decode(data, (uint256, StakeId, StakeId, uint128));
            result = abi.encode(_moveStake(original.addr(), fromStakeId, toStakeId, amount));
        } else if (callType == VE33_CLAIM_POOL_FEES) {
            (, StakeId stakeId, PoolKey memory poolKey) = abi.decode(data, (uint256, StakeId, PoolKey));
            (uint128 amount0, uint128 amount1) = _claimPoolFees(original.addr(), stakeId, poolKey, original.addr());
            result = abi.encode(amount0, amount1);
        } else if (callType == VE33_SCHEDULE_EMISSIONS) {
            (, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, uint64, uint64, uint224));
            result = abi.encode(_scheduleEmissions(original.addr(), startTime, endTime, rewardRate));
        } else {
            revert();
        }
    }

    /// @notice Executes a forward-only swap and accounts voter fees.
    /// @dev For exact input, the Core swap amount is reduced by the extension fee; for exact output, input is grossed up.
    /// @param poolKey Pool to swap against.
    /// @param params Swap parameters supplied by the router/caller.
    /// @return balanceUpdate Balance deltas including extension fees.
    /// @return stateAfter Pool state after the Core swap.
    function _swap(PoolKey memory poolKey, SwapParameters params)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            maybeAccumulateRewards(poolKey);
            int32 tickBefore = CORE.poolState(poolId).tick();

            PoolVoteState storage poolVoteState = poolVoteStates[poolId];
            uint64 swapFee = _swapFee(poolVoteState);
            int128 fee0;
            int128 fee1;
            uint128 exactInMaxFee;
            SwapParameters coreParams = params;

            if (swapFee != 0 && !params.isExactOut()) {
                uint128 amount = uint128(uint256(int256(params.amount())));
                uint128 fee = exactInMaxFee = computeFee(amount, swapFee);
                coreParams = createSwapParameters(
                    params.sqrtRatioLimit(),
                    SafeCastLib.toInt128(uint256(amount - fee)),
                    params.isToken1(),
                    params.skipAhead()
                );
            }

            (balanceUpdate, stateAfter) = CORE.swap(0, poolKey, coreParams);

            if (balanceUpdate.delta0() > 0) {
                uint128 inputAmount = uint128(uint256(int256(balanceUpdate.delta0())));
                uint128 inputFee = amountBeforeFee(inputAmount, swapFee) - inputAmount;
                int128 fee = SafeCastLib.toInt128(
                    params.isExactOut() ? inputFee : FixedPointMathLib.min(inputFee, exactInMaxFee)
                );
                fee0 = fee;
                balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + fee, balanceUpdate.delta1());
            } else if (balanceUpdate.delta1() > 0) {
                uint128 inputAmount = uint128(uint256(int256(balanceUpdate.delta1())));
                uint128 inputFee = amountBeforeFee(inputAmount, swapFee) - inputAmount;
                int128 fee = SafeCastLib.toInt128(
                    params.isExactOut() ? inputFee : FixedPointMathLib.min(inputFee, exactInMaxFee)
                );
                fee1 = fee;
                balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + fee);
            }

            if (fee0 != 0 || fee1 != 0) {
                CORE.updateSavedBalances(poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), fee0, fee1);
                _accountPoolFees(poolId, uint128(uint256(int256(fee0))), uint128(uint256(int256(fee1))));
            }

            _updateCrossedTicks(poolKey, poolId, tickBefore, stateAfter.tick(), params.skipAhead());
        }
    }

    /// @notice Updates a position reward snapshot before liquidity changes.
    /// @dev Preserves currently accrued rewards by adjusting the snapshot against next liquidity.
    /// @param owner Position owner.
    /// @param poolKey Pool containing the position.
    /// @param positionId Position being updated.
    /// @param liquidityDelta Liquidity change passed to Core.
    function _beforeUpdatePosition(address owner, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        private
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;

        if (liquidityDelta != 0) {
            PoolState coreState = CORE.poolState(poolId);
            int32 tick = coreState.tick();
            uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
            uint256 rewardsInsidePerLiquidity =
                _getRewardsInsidePerLiquidity(poolId, tick, positionId.tickLower(), positionId.tickUpper());
            uint256 snapshot = positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];
            uint256 amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

            if (poolKey.config.isStableswap()) {
                _updateStableswapTickRewardsPerLiquidityOutside(poolKey, poolId, coreState, liquidityDelta);
            } else {
                _updateTickRewardsPerLiquidityOutside(poolId, tick, positionId.tickLower(), liquidityDelta);
                _updateTickRewardsPerLiquidityOutside(poolId, tick, positionId.tickUpper(), liquidityDelta);
            }

            if (liquidityNext == 0) {
                positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = 0;
            } else {
                uint256 rewardsInsideNextPerLiquidity =
                    _getRewardsInsidePerLiquidity(poolId, tick, positionId.tickLower(), positionId.tickUpper());
                unchecked {
                    positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] =
                        rewardsInsideNextPerLiquidity - ((amount << 128) / liquidityNext);
                }
            }
        }
    }

    /// @notice Validates that a new or moved-to stake is active and nonzero.
    /// @param stakeId Proposed stake id.
    /// @param amount Amount being staked or moved.
    function _validateNewStake(StakeId stakeId, uint128 amount) private view {
        uint64 endTime = stakeId.endTime();
        if (amount == 0 || endTime <= block.timestamp || endTime > block.timestamp + MAX_STAKE_DURATION) {
            revert InvalidStake();
        }
    }

    /// @notice Adds stake and records the saved balance under this extension.
    /// @dev Does not transfer tokens; the calling stake representation settles the payment in the same Core lock.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id.
    /// @param amount Amount of stake to add.
    /// @return nextAmount Stake amount after the increase.
    function _stake(address owner, StakeId stakeId, uint128 amount) private returns (uint128 nextAmount) {
        _validateNewStake(stakeId, amount);

        _clearVotes(owner, stakeId);
        nextAmount = stakeAmounts[owner][stakeId] + amount;
        stakeAmounts[owner][stakeId] = nextAmount;
        _updateStakeSavedBalance(owner, stakeId, int256(uint256(amount)));

        emit StakeIncreased(owner, stakeId, amount);
    }

    /// @notice Removes stake from an expired stake and records the saved-balance decrease.
    /// @dev Does not transfer tokens; the calling stake representation withdraws tokens from Core.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id.
    /// @return unstaked Amount removed from the stake.
    function _unstake(address owner, StakeId stakeId) private returns (uint128 unstaked) {
        uint64 endTime = stakeId.endTime();
        if (block.timestamp < endTime) revert InvalidStake();

        unstaked = stakeAmounts[owner][stakeId];
        if (unstaked == 0) revert InvalidStake();

        _clearVotes(owner, stakeId);
        stakeAmounts[owner][stakeId] = 0;
        _updateStakeSavedBalance(owner, stakeId, -int256(uint256(unstaked)));

        emit StakeDecreased(owner, stakeId, unstaked);
    }

    /// @notice Moves stake between two stake keys for the same owner.
    /// @dev Used by wrappers to model extension by withdrawing one stake key and staking into another without transfers.
    /// @param owner Locker representation that owns both stake keys.
    /// @param fromStakeId Source stake id.
    /// @param toStakeId Destination stake id.
    /// @param amount Amount of stake to move.
    /// @return nextAmount Destination stake amount after the move.
    function _moveStake(address owner, StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        private
        returns (uint128 nextAmount)
    {
        _validateNewStake(toStakeId, amount);

        uint128 currentAmount = stakeAmounts[owner][fromStakeId];
        if (amount > currentAmount) revert InvalidStake();

        _clearVotes(owner, fromStakeId);
        _clearVotes(owner, toStakeId);
        stakeAmounts[owner][fromStakeId] = currentAmount - amount;
        nextAmount = stakeAmounts[owner][toStakeId] + amount;
        stakeAmounts[owner][toStakeId] = nextAmount;
        _updateStakeSavedBalance(owner, fromStakeId, -int256(uint256(amount)));
        _updateStakeSavedBalance(owner, toStakeId, int256(uint256(amount)));

        emit StakeMoved(owner, fromStakeId, toStakeId);
    }

    /// @notice Applies a stake's votes to pool accounting.
    /// @dev Clears old votes first. Duplicate pools, mismatched lengths, non-extension pools, and zero total weight revert.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake whose voting power is allocated.
    /// @param poolKeys Pools receiving votes.
    /// @param weights Relative weights for each pool.
    /// @param swapFees Explicit swap fee votes for each pool.
    function _vote(
        address owner,
        StakeId stakeId,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint64[] memory swapFees
    ) private {
        if (poolKeys.length != weights.length || poolKeys.length != swapFees.length) {
            revert InvalidVote();
        }

        uint128 power = _votingPower(owner, stakeId);
        if (power == 0) revert InvalidVote();

        uint256 length = weights.length;
        uint256 totalWeight;
        for (uint256 i; i < length;) {
            totalWeight += weights[i];
            PoolId poolId = poolKeys[i].toPoolId();
            bool invalidConcentratedSpacing;
            if (poolKeys[i].config.isConcentrated()) {
                uint32 tickSpacing = poolKeys[i].config.concentratedTickSpacing();
                invalidConcentratedSpacing = !isPowerOfFour(tickSpacing);
            }
            if (
                poolKeys[i].config.extension() != address(this) || poolKeys[i].config.fee() != 0
                    || invalidConcentratedSpacing
            ) {
                revert InvalidVote();
            }
            for (uint256 j; j < i;) {
                if (PoolId.unwrap(poolId) == PoolId.unwrap(poolKeys[j].toPoolId())) revert InvalidVote();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (totalWeight == 0) revert InvalidVote();

        _clearVotes(owner, stakeId);
        for (uint256 i; i < length;) {
            uint128 weight = uint128((uint256(power) * weights[i]) / totalWeight);
            if (weight != 0) {
                PoolId poolId = poolKeys[i].toPoolId();
                uint64 swapFee = capFee(swapFees[i]);
                _accumulatePoolEmissionsForVote(poolId, poolKeys[i]);

                PoolVoteState storage poolState = poolVoteStates[poolId];
                VePoolPosition storage vePool = vePoolPositions[owner][stakeId][poolId];

                unchecked {
                    poolState.weight += weight;
                    poolState.feeWeightSum += uint192(uint256(weight) * swapFee);
                    totalVoteWeight += weight;
                }

                vePool.weight = weight;
                vePool.swapFee = swapFee;
                vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
                vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
                votedPools[owner][stakeId].push(poolId);
            }
            unchecked {
                ++i;
            }
        }

        emit Voted(owner, stakeId);
    }

    /// @notice Adds swap fees to a pool's voter fee-growth accumulators.
    /// @param poolId Pool receiving fees.
    /// @param amount0 Token0 fee amount.
    /// @param amount1 Token1 fee amount.
    function _accountPoolFees(PoolId poolId, uint128 amount0, uint128 amount1) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 weight = poolState.weight;
        if (weight != 0) {
            unchecked {
                poolState.feeGrowth0X128 += (uint256(amount0) << 128) / weight;
                poolState.feeGrowth1X128 += (uint256(amount1) << 128) / weight;
            }
        }

        emit PoolFeesAccounted(poolId, amount0, amount1);
    }

    /// @notice Claims accrued voter fees while this extension is handling a forwarded call.
    /// @dev Subtracts fees from the extension's saved balance. The forwarding locker withdraws the tokens.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake claiming fees.
    /// @param poolKey Pool whose fees are claimed.
    /// @param recipient Account recorded in the claim event.
    /// @return amount0 Claimed token0 amount.
    /// @return amount1 Claimed token1 amount.
    function _claimPoolFees(address owner, StakeId stakeId, PoolKey memory poolKey, address recipient)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();

        PoolVoteState storage poolState = poolVoteStates[poolId];
        VePoolPosition storage vePool = vePoolPositions[owner][stakeId][poolId];
        (amount0, amount1) = _vePoolFees(poolState, vePool);
        vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
        vePool.feeGrowth1X128 = poolState.feeGrowth1X128;

        if (amount0 != 0 || amount1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );
        }

        emit PoolFeesClaimed(poolId, owner, stakeId, recipient, amount0, amount1);
    }

    /// @notice Schedules global ve emissions for a chosen valid time range.
    /// @dev Saves the required amount in Core; the forwarding locker must pay `stakeToken` into Core.
    /// @param funder Account recorded in the schedule event.
    /// @param startTime Emission schedule start time, or zero for immediate start.
    /// @param endTime Emission schedule end time.
    /// @param rewardRate Q32 global emission rate in stake tokens per second.
    /// @return amount Amount of `stakeToken` required by the schedule.
    function _scheduleEmissions(address funder, uint64 startTime, uint64 endTime, uint224 rewardRate)
        private
        returns (uint224 amount)
    {
        if (
            !isTimeValid({currentTime: block.timestamp, time: startTime})
                || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= startTime
                || endTime <= block.timestamp
        ) {
            revert InvalidTimestamps();
        }

        _accrueEmissions();

        unchecked {
            uint256 realDuration = uint256(endTime) - FixedPointMathLib.max(block.timestamp, startTime);
            amount = uint224(((realDuration * rewardRate) + type(uint32).max) >> 32);
        }

        if (amount == 0) revert EmissionAmountTooSmall();
        if (amount > type(uint128).max) revert RewardAmountOverflow();
        emissionReserve += amount;
        _updateRewardSavedBalance(int256(uint256(amount)));

        int256 rewardRateDelta = int256(uint256(rewardRate));
        if (startTime > block.timestamp) {
            _updateEmissionTime(startTime, rewardRateDelta);
        } else {
            emissionRate = uint224(_addRewardRate(emissionRate, rewardRateDelta));
        }

        _updateEmissionTime(endTime, -rewardRateDelta);

        emit EmissionsScheduled(funder, startTime, endTime, rewardRate, amount);
    }

    /// @notice Schedules reward-token emissions for a pool.
    /// @dev Updates the reward reserve saved balance and the pool reward-rate schedule.
    /// @param poolKey Pool receiving rewards.
    /// @param startTime Stream start time, or zero for immediate scheduling.
    /// @param endTime Stream end time.
    /// @param rewardRate Q32 reward rate in tokens per second.
    /// @return amount Total token amount required for the schedule.
    function _scheduleRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        private
        returns (uint224 amount)
    {
        if (
            !isTimeValid({currentTime: block.timestamp, time: startTime})
                || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= startTime
                || endTime <= block.timestamp
        ) {
            revert InvalidTimestamps();
        }

        maybeAccumulateRewards(poolKey);

        unchecked {
            uint256 realDuration = uint256(endTime) - FixedPointMathLib.max(block.timestamp, startTime);
            amount = uint224(((realDuration * rewardRate) + type(uint32).max) >> 32);
        }

        if (amount > type(uint128).max) revert RewardAmountOverflow();
        if (amount != 0) _updateRewardSavedBalance(int256(uint256(amount)));

        PoolId poolId = poolKey.toPoolId();
        int256 rewardRateDelta = int256(uint256(rewardRate));
        if (startTime > block.timestamp) {
            _updateTime(poolId, startTime, rewardRateDelta);
        } else {
            Ve33RewardPoolState state = poolRewardState[poolId];
            poolRewardState[poolId] = createVe33RewardPoolState(
                state.lastAccumulated(), uint224(_addRewardRate(state.rewardRate(), rewardRateDelta))
            );
        }

        _updateTime(poolId, endTime, -rewardRateDelta);

        emit PoolRewardsScheduled(poolId, startTime, endTime, rewardRate, amount);
    }

    /// @notice Donates rewards immediately to current pool liquidity.
    /// @dev If active liquidity is zero, the donated amount is saved but not assigned to LP reward growth.
    /// @param poolKey Pool receiving the donation.
    /// @param amount Amount donated.
    /// @return donated Amount accepted.
    function _donateRewards(PoolKey memory poolKey, uint128 amount) private returns (uint128 donated) {
        donated = amount;
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        if (amount != 0) {
            uint128 liquidity = _activeRewardLiquidity(poolKey, CORE.poolState(poolId));
            _updateRewardSavedBalance(int256(uint256(amount)));
            if (liquidity != 0) {
                unchecked {
                    rewardsGlobalPerLiquidity[poolId] += (uint256(amount) << 128) / liquidity;
                }
            }
        }

        emit RewardsDonated(poolId, amount);
    }

    /// @notice Returns liquidity eligible for reward growth at the current pool price.
    /// @dev Stableswap active liquidity is zero outside its configured active range.
    /// @param poolKey Pool whose reward liquidity is being checked.
    /// @param coreState Current Core pool state.
    /// @return liquidity In-range liquidity eligible for LP rewards.
    function _activeRewardLiquidity(PoolKey memory poolKey, PoolState coreState)
        private
        pure
        returns (uint128 liquidity)
    {
        liquidity = coreState.liquidity();
        if (liquidity != 0 && poolKey.config.isStableswap()) {
            (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
            int32 tick = coreState.tick();
            if (tick < lower || tick >= upper) liquidity = 0;
        }
    }

    /// @notice Claims reward tokens earned by an LP position.
    /// @dev Uses range-aware reward growth and then resets the position snapshot.
    /// @param poolKey Pool containing the position.
    /// @param owner Position owner.
    /// @param positionId Position claiming rewards.
    /// @param recipient Account recorded in the claim event.
    /// @return amount Claimed reward amount.
    function _claimRewards(PoolKey memory poolKey, address owner, PositionId positionId, address recipient)
        private
        returns (uint256 amount)
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;
        uint256 snapshot = positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];

        uint256 rewardsInsidePerLiquidity = _getRewardsInsidePerLiquidity(
            poolId, CORE.poolState(poolId).tick(), positionId.tickLower(), positionId.tickUpper()
        );
        amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

        positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = liquidity == 0 ? 0 : rewardsInsidePerLiquidity;

        if (amount > type(uint128).max) revert RewardAmountOverflow();

        if (amount != 0) {
            uint128 amountUint128 = uint128(amount);
            _updateRewardSavedBalance(-int256(uint256(amountUint128)));
        }

        emit RewardsClaimed(poolId, owner, positionId, recipient, amount);
    }

    /// @notice Clears all active votes for a stake.
    /// @dev Pending voter fees are discarded when a vote is fully cleared, matching zero-liquidity Core positions.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose votes are cleared.
    function _clearVotes(address owner, StakeId stakeId) private {
        PoolId[] storage pools = votedPools[owner][stakeId];
        uint256 length = pools.length;
        if (length == 0) return;

        for (uint256 i; i < length;) {
            PoolId poolId = pools[i];
            _accumulatePoolEmissionsForVote(poolId, storedPoolKeys[poolId]);

            VePoolPosition storage vePool = vePoolPositions[owner][stakeId][poolId];
            uint128 weight = vePool.weight;
            if (weight != 0) {
                PoolVoteState storage poolState = poolVoteStates[poolId];
                _setVePoolWeight(poolState, vePool, 0);
                unchecked {
                    poolState.weight -= weight;
                    poolState.feeWeightSum -= uint192(uint256(weight) * vePool.swapFee);
                    totalVoteWeight -= weight;
                }
            }
            unchecked {
                ++i;
            }
        }

        delete votedPools[owner][stakeId];
    }

    /// @notice Reduces a stake's active vote weights to a target total weight.
    /// @dev Accrues reward and voter-fee accounting before changing future weights.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose votes are refreshed.
    /// @param targetWeight Current decayed voting power for the stake.
    /// @return previousWeight Total active vote weight before refresh.
    /// @return nextWeight Total active vote weight after refresh.
    function _pokeVotes(address owner, StakeId stakeId, uint256 targetWeight)
        private
        returns (uint256 previousWeight, uint256 nextWeight)
    {
        PoolId[] storage pools = votedPools[owner][stakeId];
        uint256 length = pools.length;
        if (length == 0) return (0, 0);

        for (uint256 i; i < length;) {
            PoolId poolId = pools[i];
            _accumulatePoolEmissionsForVote(poolId, storedPoolKeys[poolId]);
            previousWeight += vePoolPositions[owner][stakeId][poolId].weight;
            unchecked {
                ++i;
            }
        }

        if (targetWeight >= previousWeight) return (previousWeight, previousWeight);
        nextWeight = targetWeight;

        if (targetWeight == 0) {
            for (uint256 i; i < length;) {
                PoolId poolId = pools[i];
                VePoolPosition storage vePool = vePoolPositions[owner][stakeId][poolId];
                uint128 oldWeight = vePool.weight;
                if (oldWeight != 0) {
                    PoolVoteState storage poolState = poolVoteStates[poolId];
                    _setVePoolWeight(poolState, vePool, 0);
                    unchecked {
                        poolState.weight -= oldWeight;
                        poolState.feeWeightSum -= uint192(uint256(oldWeight) * vePool.swapFee);
                        totalVoteWeight -= oldWeight;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            delete votedPools[owner][stakeId];
        } else {
            uint256 remainingPreviousWeight = previousWeight;
            uint256 remainingNextWeight = targetWeight;

            for (uint256 i; i < length;) {
                PoolId poolId = pools[i];
                VePoolPosition storage vePool = vePoolPositions[owner][stakeId][poolId];
                uint128 oldWeight = vePool.weight;
                uint128 newWeight = oldWeight == remainingPreviousWeight
                    ? uint128(remainingNextWeight)
                    : uint128((uint256(oldWeight) * targetWeight) / previousWeight);

                if (oldWeight != newWeight) {
                    PoolVoteState storage poolState = poolVoteStates[poolId];
                    _setVePoolWeight(poolState, vePool, newWeight);
                    unchecked {
                        poolState.weight = poolState.weight - oldWeight + newWeight;
                        poolState.feeWeightSum = poolState.feeWeightSum - uint192(uint256(oldWeight) * vePool.swapFee)
                            + uint192(uint256(newWeight) * vePool.swapFee);
                        totalVoteWeight = totalVoteWeight - oldWeight + newWeight;
                    }
                }

                unchecked {
                    remainingPreviousWeight -= oldWeight;
                    remainingNextWeight -= newWeight;
                    ++i;
                }
            }
        }
    }

    /// @notice Computes voter fees owed to a stake's pool position.
    /// @param poolState Pool fee-growth state.
    /// @param vePool Stake's pool vote position.
    /// @return amount0 Owed token0 fees.
    /// @return amount1 Owed token1 fees.
    function _vePoolFees(PoolVoteState storage poolState, VePoolPosition storage vePool)
        private
        view
        returns (uint128 amount0, uint128 amount1)
    {
        uint128 weight = vePool.weight;
        if (weight != 0) {
            unchecked {
                amount0 = uint128(
                    FixedPointMathLib.fullMulDivN(poolState.feeGrowth0X128 - vePool.feeGrowth0X128, weight, 128)
                );
                amount1 = uint128(
                    FixedPointMathLib.fullMulDivN(poolState.feeGrowth1X128 - vePool.feeGrowth1X128, weight, 128)
                );
            }
        }
    }

    /// @notice Changes a stake's pool vote weight while preserving fees already accrued under the old weight.
    /// @dev Mirrors Core position fee snapshot adjustment. If `nextWeight` is zero, pending fees are discarded.
    /// @param poolState Pool fee-growth state.
    /// @param vePool Stake's pool vote position.
    /// @param nextWeight New vote weight for the stake in this pool.
    function _setVePoolWeight(PoolVoteState storage poolState, VePoolPosition storage vePool, uint128 nextWeight)
        private
    {
        if (nextWeight == 0) {
            vePool.weight = 0;
            vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
            vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
        } else {
            (uint128 amount0, uint128 amount1) = _vePoolFees(poolState, vePool);
            vePool.weight = nextWeight;
            unchecked {
                vePool.feeGrowth0X128 = poolState.feeGrowth0X128 - ((uint256(amount0) << 128) / nextWeight);
                vePool.feeGrowth1X128 = poolState.feeGrowth1X128 - ((uint256(amount1) << 128) / nextWeight);
            }
        }
    }

    /// @notice Accrues pool emissions before vote weight changes.
    /// @dev Uninitialized pools can be voted on, but cannot accrue LP rewards until after initialization.
    function _accumulatePoolEmissionsForVote(PoolId poolId, PoolKey memory poolKey) private {
        if (CORE.poolState(poolId).isInitialized()) {
            maybeAccumulateRewards(poolKey);
        } else {
            _accrueEmissions();
            poolVoteStates[poolId].emissionGrowthGlobalX128Snapshot = emissionGrowthGlobalX128;
        }
    }

    /// @notice Accrues a pool's share of global emissions since its last pool-emission snapshot.
    /// @param poolId Pool whose emission share is accrued.
    /// @return amount Amount of stake-token emissions assigned to the pool.
    function _poolEmissionRewardsAccrued(PoolId poolId) private returns (uint256 amount) {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 emissionGrowthGlobalX128_ = emissionGrowthGlobalX128;
        uint256 snapshot = poolState.emissionGrowthGlobalX128Snapshot;
        if (snapshot != emissionGrowthGlobalX128_) {
            poolState.emissionGrowthGlobalX128Snapshot = emissionGrowthGlobalX128_;

            uint128 weight = poolState.weight;
            if (weight != 0) {
                unchecked {
                    amount = FixedPointMathLib.fullMulDivN(emissionGrowthGlobalX128_ - snapshot, weight, 128);
                }
            }
        }
    }

    /// @notice Accrues global emissions into `emissionGrowthGlobalX128`.
    /// @return zero Always zero, used as a compact loop initializer.
    function _accrueEmissions() private returns (uint256 zero) {
        uint256 lastAccrued = emissionsLastAccrued;
        if (lastAccrued == block.timestamp) return 0;

        uint256 time = lastAccrued;
        uint224 rate = emissionRate;

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) = _searchForNextEmissionTime(lastAccrued, time, block.timestamp);

            uint128 weight = totalVoteWeight;
            uint256 amount;
            unchecked {
                amount = (uint256(rate) * (eventTime - time)) >> 32;
            }
            if (weight != 0) {
                emissionGrowthGlobalX128 += FixedPointMathLib.fullMulDiv(amount, 1 << 128, weight);
            }
            if (initialized) {
                rate = uint224(_addRewardRate(rate, emissionRateDeltaAtTime[uint64(eventTime)]));
                delete emissionRateDeltaAtTime[uint64(eventTime)];
                _flipEmissionTime(eventTime);
            }
            time = eventTime;
        }

        emissionRate = rate;
        emissionsLastAccrued = uint64(block.timestamp);
    }

    /// @notice Computes a pool's active swap fee from current voter weights.
    /// @dev EVM `div` returns zero when `weight` is zero, so unvoted pools have no extension swap fee.
    function _swapFee(PoolVoteState storage poolState) private view returns (uint64 swapFee) {
        uint256 feeWeightSum = poolState.feeWeightSum;
        uint256 weight = poolState.weight;
        assembly ("memory-safe") {
            swapFee := div(feeWeightSum, weight)
        }
    }

    /// @notice Updates tick reward snapshots for ticks crossed by a forwarded swap.
    /// @dev Mirrors Core fee-outside inversion so reward growth remains range-aware.
    /// @param poolKey Pool that was swapped.
    /// @param poolId Id of `poolKey`.
    /// @param tickBefore Tick before the swap.
    /// @param tickAfter Tick after the swap.
    /// @param skipAhead Tick-bitmap skip-ahead hint supplied to the swap.
    function _updateCrossedTicks(
        PoolKey memory poolKey,
        PoolId poolId,
        int32 tickBefore,
        int32 tickAfter,
        uint256 skipAhead
    ) private {
        if (tickBefore == tickAfter) return;

        uint256 rewardsGlobalPerLiquidity_ = rewardsGlobalPerLiquidity[poolId];

        if (poolKey.config.isStableswap()) {
            (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
            if (tickAfter > tickBefore) {
                if (tickBefore < lower && tickAfter >= lower) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][lower] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][lower];
                    }
                }
                if (tickBefore < upper && tickAfter >= upper) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][upper] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][upper];
                    }
                }
            } else {
                if (tickBefore >= upper && tickAfter < upper) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][upper] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][upper];
                    }
                }
                if (tickBefore >= lower && tickAfter < lower) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][lower] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][lower];
                    }
                }
            }
            return;
        }

        uint32 tickSpacing = poolKey.config.concentratedTickSpacing();

        bool priceIncreasing = tickAfter > tickBefore;
        if (!priceIncreasing) {
            int32 tick = tickBefore;
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.prevInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (!initialized || tick <= tickAfter) break;
                unchecked {
                    tickRewardsOutsidePerLiquidity[poolId][tick] =
                        rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][tick];
                    tick--;
                }
            }
        }
        if (priceIncreasing) {
            int32 tick = tickBefore;
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.nextInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (!initialized || tick > tickAfter) break;
                unchecked {
                    tickRewardsOutsidePerLiquidity[poolId][tick] =
                        rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][tick];
                }
            }
        }
    }

    /// @notice Updates the saved balance for unassigned LP reward tokens.
    /// @param delta Signed reward-reserve balance delta.
    function _updateRewardSavedBalance(int256 delta) private {
        CORE.updateSavedBalances(stakeToken, address(type(uint160).max), bytes32(0), delta, 0);
    }

    /// @notice Updates the saved balance for staked tokens.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose saved balance changes.
    /// @param delta Signed staked-token balance delta.
    function _updateStakeSavedBalance(address owner, StakeId stakeId, int256 delta) private {
        CORE.updateSavedBalances(stakeToken, address(type(uint160).max), _stakeSavedBalanceId(owner, stakeId), delta, 0);
    }

    /// @notice Computes the Core saved-balance id for a staked token balance.
    function _stakeSavedBalanceId(address owner, StakeId stakeId) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(0x20, stakeId)
            result := keccak256(0x0c, 0x34)
        }
    }

    /// @notice Computes reward growth inside a position's tick range.
    /// @param poolId Pool containing the position.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @return rewardsInsidePerLiquidity Reward growth inside the range.
    function _getRewardsInsidePerLiquidity(PoolId poolId, int32 tickLower, int32 tickUpper)
        private
        view
        returns (uint256 rewardsInsidePerLiquidity)
    {
        rewardsInsidePerLiquidity =
            _getRewardsInsidePerLiquidity(poolId, CORE.poolState(poolId).tick(), tickLower, tickUpper);
    }

    /// @notice Computes reward growth inside a position's tick range using a known current tick.
    /// @param poolId Pool containing the position.
    /// @param tick Current pool tick.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @return rewardsInsidePerLiquidity Reward growth inside the range.
    function _getRewardsInsidePerLiquidity(PoolId poolId, int32 tick, int32 tickLower, int32 tickUpper)
        private
        view
        returns (uint256 rewardsInsidePerLiquidity)
    {
        uint256 lower = tickRewardsOutsidePerLiquidity[poolId][tickLower];
        uint256 upper = tickRewardsOutsidePerLiquidity[poolId][tickUpper];

        unchecked {
            if (tick < tickLower) {
                rewardsInsidePerLiquidity = lower - upper;
            } else if (tick < tickUpper) {
                rewardsInsidePerLiquidity = rewardsGlobalPerLiquidity[poolId] - upper - lower;
            } else {
                rewardsInsidePerLiquidity = upper - lower;
            }
        }
    }

    /// @notice Updates reward-outside state when a concentrated-position boundary becomes initialized or uninitialized.
    /// @param poolId Pool containing the tick.
    /// @param tickCurrent Current pool tick.
    /// @param tick Position boundary tick.
    /// @param liquidityDelta Position liquidity delta.
    function _updateTickRewardsPerLiquidityOutside(PoolId poolId, int32 tickCurrent, int32 tick, int128 liquidityDelta)
        private
    {
        (, uint128 liquidityNet) = CORE.poolTicks(poolId, tick);
        uint128 liquidityNetNext = addLiquidityDelta(liquidityNet, liquidityDelta);
        if ((liquidityNet == 0) != (liquidityNetNext == 0)) {
            delete tickRewardsOutsidePerLiquidity[poolId][tick];
            if (liquidityNetNext != 0) {
                tickRewardsOutsidePerLiquidity[poolId][tick] =
                    tickCurrent >= tick ? rewardsGlobalPerLiquidity[poolId] : 0;
            }
        }
    }

    /// @notice Updates reward-outside state when stableswap active liquidity appears or disappears.
    /// @param poolKey Stableswap pool key.
    /// @param poolId Id of `poolKey`.
    /// @param liquidityDelta Position liquidity delta.
    function _updateStableswapTickRewardsPerLiquidityOutside(
        PoolKey memory poolKey,
        PoolId poolId,
        PoolState coreState,
        int128 liquidityDelta
    ) private {
        uint128 liquidity = coreState.liquidity();
        uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
        if ((liquidity == 0) != (liquidityNext == 0)) {
            (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
            delete tickRewardsOutsidePerLiquidity[poolId][lower];
            delete tickRewardsOutsidePerLiquidity[poolId][upper];
            if (liquidityNext != 0) {
                int32 tick = coreState.tick();
                uint256 rewardsGlobalPerLiquidity_ = rewardsGlobalPerLiquidity[poolId];
                tickRewardsOutsidePerLiquidity[poolId][lower] = tick >= lower ? rewardsGlobalPerLiquidity_ : 0;
                tickRewardsOutsidePerLiquidity[poolId][upper] = tick >= upper ? rewardsGlobalPerLiquidity_ : 0;
            }
        }
    }

    /// @notice Computes reward amount from a per-liquidity snapshot.
    /// @param snapshot Previous reward growth snapshot.
    /// @param rewardsInsidePerLiquidity_ Current reward growth inside the position range.
    /// @param liquidity Position liquidity.
    /// @return amount Accrued reward amount.
    function _positionRewards(uint256 snapshot, uint256 rewardsInsidePerLiquidity_, uint128 liquidity)
        private
        pure
        returns (uint256 amount)
    {
        if (liquidity != 0) {
            unchecked {
                amount = FixedPointMathLib.fullMulDivN(rewardsInsidePerLiquidity_ - snapshot, liquidity, 128);
            }
        }
    }

    /// @notice Adds a signed reward-rate delta to a current rate.
    /// @param rewardRate Current reward rate.
    /// @param delta Signed rate delta.
    /// @return next Next reward rate.
    function _addRewardRate(uint256 rewardRate, int256 delta) private pure returns (uint256 next) {
        unchecked {
            next = uint256(int256(rewardRate) + delta);
        }
        if (next > type(uint224).max) revert MaxRateDeltaPerTime();
    }

    /// @notice Adds a signed change to a scheduled reward-rate delta and checks the bound.
    /// @param rateDelta Current scheduled delta.
    /// @param change Signed change to apply.
    /// @return next Next scheduled delta.
    function _addConstrainRateDelta(int256 rateDelta, int256 change) private pure returns (int256 next) {
        unchecked {
            next = rateDelta + change;
        }

        if (FixedPointMathLib.abs(next) > VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA) {
            revert MaxRateDeltaPerTime();
        }
    }

    /// @notice Updates a pool's scheduled reward-rate delta at a valid time.
    /// @param poolId Pool whose schedule changes.
    /// @param time Valid schedule time.
    /// @param delta Signed reward-rate delta to add at `time`.
    function _updateTime(PoolId poolId, uint64 time, int256 delta) private {
        int256 rateDelta = rewardRateDeltaAtTime[poolId][time];
        int256 rateDeltaNext = _addConstrainRateDelta(rateDelta, delta);

        rewardRateDeltaAtTime[poolId][time] = rateDeltaNext;

        if ((rateDelta == 0) != (rateDeltaNext == 0)) {
            _flipTime(poolId, time);
        }
    }

    /// @notice Updates a global scheduled emission-rate delta at a valid time.
    /// @param time Valid schedule time.
    /// @param delta Signed emission-rate delta to add at `time`.
    function _updateEmissionTime(uint64 time, int256 delta) private {
        int256 rateDelta = emissionRateDeltaAtTime[time];
        int256 rateDeltaNext = _addConstrainRateDelta(rateDelta, delta);

        emissionRateDeltaAtTime[time] = rateDeltaNext;

        if ((rateDelta == 0) != (rateDeltaNext == 0)) {
            _flipEmissionTime(time);
        }
    }

    /// @notice Toggles whether a pool has a nonzero reward-rate delta at a valid time.
    /// @param poolId Pool whose bitmap changes.
    /// @param time Valid schedule time.
    function _flipTime(PoolId poolId, uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            initializedTimeBitmap[poolId][word] ^= uint256(1) << index;
        }
    }

    /// @notice Toggles whether a global emission-rate decrease is scheduled at a valid time.
    /// @param time Valid schedule time.
    function _flipEmissionTime(uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            emissionInitializedTimeBitmap[word] ^= uint256(1) << index;
        }
    }

    /// @notice Finds the next initialized global emission schedule time at or after `fromTime`.
    /// @param fromTime Valid time to begin searching from.
    /// @return nextTime Next initialized time in the bitmap word.
    /// @return isInitialized Whether an initialized time was found.
    function _findNextEmissionTime(uint256 fromTime) private view returns (uint256 nextTime, bool isInitialized) {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            Bitmap bitmap = Bitmap.wrap(emissionInitializedTimeBitmap[word]);
            uint256 nextIndex = bitmap.geSetBit(uint8(index));

            isInitialized = nextIndex != 0;

            nextIndex = (nextIndex - 1) % 256;

            nextTime = bitmapWordAndIndexToTime(word, nextIndex);
        }
    }

    /// @notice Searches global emission schedule times until an initialized time or upper bound is reached.
    /// @param lastAccrued Full last-accrued timestamp used for valid-time alignment.
    /// @param fromTime Search start.
    /// @param untilTime Search upper bound.
    /// @return nextTime Next initialized time or `untilTime`.
    /// @return isInitialized Whether `nextTime` is an initialized emission schedule time.
    function _searchForNextEmissionTime(uint256 lastAccrued, uint256 fromTime, uint256 untilTime)
        private
        view
        returns (uint256 nextTime, bool isInitialized)
    {
        unchecked {
            nextTime = fromTime;
            while (!isInitialized && nextTime != untilTime) {
                uint256 nextValid = nextValidTime(lastAccrued, nextTime);
                if (nextValid == 0) {
                    nextTime = untilTime;
                    break;
                }
                (nextTime, isInitialized) = _findNextEmissionTime(nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    isInitialized = false;
                }
            }
        }
    }

    /// @notice Finds the next initialized reward schedule time at or after `fromTime`.
    /// @param poolId Pool whose schedule is searched.
    /// @param fromTime Valid time to begin searching from.
    /// @return nextTime Next initialized time in the bitmap word.
    /// @return isInitialized Whether an initialized time was found.
    function _findNextInitializedTime(PoolId poolId, uint256 fromTime)
        private
        view
        returns (uint256 nextTime, bool isInitialized)
    {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            Bitmap bitmap = Bitmap.wrap(initializedTimeBitmap[poolId][word]);
            uint256 nextIndex = bitmap.geSetBit(uint8(index));

            isInitialized = nextIndex != 0;

            nextIndex = (nextIndex - 1) % 256;

            nextTime = bitmapWordAndIndexToTime(word, nextIndex);
        }
    }

    /// @notice Searches reward schedule times until an initialized time or upper bound is reached.
    /// @param poolId Pool whose schedule is searched.
    /// @param lastAccumulated Full last-accumulated timestamp used for valid-time alignment.
    /// @param fromTime Search start.
    /// @param untilTime Search upper bound.
    /// @return nextTime Next initialized time or `untilTime`.
    /// @return isInitialized Whether `nextTime` is an initialized schedule time.
    function _searchForNextInitializedTime(PoolId poolId, uint256 lastAccumulated, uint256 fromTime, uint256 untilTime)
        private
        view
        returns (uint256 nextTime, bool isInitialized)
    {
        unchecked {
            nextTime = fromTime;
            while (!isInitialized && nextTime != untilTime) {
                uint256 nextValid = nextValidTime(lastAccumulated, nextTime);
                (nextTime, isInitialized) = _findNextInitializedTime(poolId, nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    isInitialized = false;
                }
            }
        }
    }
}
