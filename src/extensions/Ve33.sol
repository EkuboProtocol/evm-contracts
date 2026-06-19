// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
import {
    capFee,
    defaultFeeForStableswapAmplification as defaultVeFeeForStableswapAmplification,
    defaultFeeForTickSpacing as defaultVeFeeForTickSpacing
} from "../math/tickSpacingFee.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "../math/timeBitmap.sol";
import {Bitmap} from "../types/bitmap.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";

// Forward call type for extension-mediated swaps.
uint256 constant VE33_SWAP = 0;
// Forward call type for claiming LP reward-token emissions.
uint256 constant VE33_CLAIM_REWARDS = 1;
// Forward call type for immediately donating reward tokens to in-range LP liquidity.
uint256 constant VE33_DONATE_REWARDS = 2;
// Forward call type for scheduling reward-token emissions.
uint256 constant VE33_ADD_REWARDS = 3;
// Forward call type for increasing a ve stake.
uint256 constant VE33_STAKE = 4;
// Forward call type for decreasing an expired ve stake.
uint256 constant VE33_UNSTAKE = 5;
// Forward call type for moving stake to a different `(salt, endTime)` key.
uint256 constant VE33_MOVE_STAKE = 6;
// Forward call type for claiming voter pool fees.
uint256 constant VE33_CLAIM_POOL_FEES = 7;
// Forward call type for funding global emissions.
uint256 constant VE33_FUND_EMISSIONS = 8;
// Forward call type for assigning global emissions to a pool.
uint256 constant VE33_TRIGGER_POOL_EMISSIONS = 9;

// Maximum absolute scheduled reward-rate delta allowed at one valid time.
uint256 constant VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint224).max / MAX_NUM_VALID_TIMES;
// Maximum ve stake duration.
uint256 constant VE33_MAX_STAKE_DURATION = 4 * 365 days;

/// @notice Packed LP reward state for a pool.
/// @dev Low 32 bits store `lastAccumulated`; high 224 bits store the Q32 reward rate.
type Ve33RewardPoolState is bytes32;

using {
    ve33LastAccumulated,
    ve33RealLastAccumulated,
    ve33RewardRate,
    ve33ParseRewardPoolState
} for Ve33RewardPoolState global;

/// @notice Returns the truncated timestamp when the pool reward state last accumulated.
function ve33LastAccumulated(Ve33RewardPoolState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

/// @notice Returns the full timestamp corresponding to the packed 32-bit last-accumulated time.
/// @dev Reconstructs the timestamp closest to `block.timestamp` to tolerate 32-bit wraparound.
function ve33RealLastAccumulated(Ve33RewardPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

/// @notice Returns the current Q32 reward rate in reward tokens per second.
function ve33RewardRate(Ve33RewardPoolState state) pure returns (uint224 rate) {
    assembly ("memory-safe") {
        rate := shr(32, state)
    }
}

/// @notice Parses the packed pool reward state.
/// @return time Truncated last-accumulated timestamp.
/// @return rate Current Q32 reward rate in reward tokens per second.
function ve33ParseRewardPoolState(Ve33RewardPoolState state) pure returns (uint32 time, uint224 rate) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(32, state)
    }
}

/// @notice Packs a reward pool state value.
/// @param _lastAccumulated Truncated last-accumulated timestamp.
/// @param _rewardRate Current Q32 reward rate in reward tokens per second.
function createVe33RewardPoolState(uint32 _lastAccumulated, uint224 _rewardRate) pure returns (Ve33RewardPoolState s) {
    assembly ("memory-safe") {
        s := or(and(_lastAccumulated, 0xffffffff), shl(32, _rewardRate))
    }
}

/// @notice Returns the Core hooks enabled by `Ve33`.
function ve33CallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
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
    /// @notice Duration of each global and per-pool emission stream.
    uint256 public constant EMISSION_DURATION = 7 days;
    /// @notice Maximum ve stake duration.
    uint256 public constant MAX_STAKE_DURATION = VE33_MAX_STAKE_DURATION;

    /// @notice Token used for ve staking, global emissions, and LP rewards.
    address public immutable stakeToken;

    /// @notice Canonical ve stake identifier.
    /// @param owner Locker representation that owns the stake in this contract.
    /// @param salt Caller-selected salt that distinguishes stakes for one owner.
    /// @param endTime Timestamp when the stake may be unstaked.
    struct StakeKey {
        address owner;
        bytes32 salt;
        uint64 endTime;
    }

    /// @notice Vote, fee, and emission allocation state for one pool.
    /// @param weight Current active vote weight assigned to the pool.
    /// @param voteSeconds Time-weighted active vote weight accrued since the pool was last triggered.
    /// @param feeGrowth0X128 Accumulated token0 fees per unit of vote weight.
    /// @param feeGrowth1X128 Accumulated token1 fees per unit of vote weight.
    /// @param feeWeightSum Sum of `weight * votedFee`, used to compute the weighted swap fee.
    /// @param lastAccrued Last timestamp when `voteSeconds` was accrued.
    /// @param swapFee Current extension swap fee.
    /// @param defaultSwapFee Swap fee used when the pool has no active votes.
    struct PoolVoteState {
        uint256 weight;
        uint256 voteSeconds;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 feeWeightSum;
        uint64 lastAccrued;
        uint64 swapFee;
        uint64 defaultSwapFee;
    }

    /// @notice Per-stake accounting for one voted pool.
    /// @param weight Active vote weight from the stake to the pool.
    /// @param swapFee Fee selected by the stake for this pool.
    /// @param feeGrowth0X128 Snapshot of pool token0 fee growth.
    /// @param feeGrowth1X128 Snapshot of pool token1 fee growth.
    /// @param accrued0 Token0 fees accrued but not claimed.
    /// @param accrued1 Token1 fees accrued but not claimed.
    struct VePoolPosition {
        uint128 weight;
        uint64 swapFee;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 accrued0;
        uint256 accrued1;
    }

    /// @notice Stake amounts by `(owner, salt, endTime)`.
    mapping(address => mapping(bytes32 => mapping(uint64 => uint128))) internal stakeAmounts;
    /// @notice Pools currently voted on by each stake id.
    mapping(bytes32 => PoolId[]) internal votedPools;
    /// @notice Per-stake, per-pool vote and fee snapshots.
    mapping(bytes32 => mapping(PoolId => VePoolPosition)) internal vePoolPositions;
    /// @notice Aggregated voting and fee state for each pool.
    mapping(PoolId => PoolVoteState) internal poolVoteStates;

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
    uint256 internal totalVoteWeight;
    /// @notice Accrued time-weighted vote weight across all pools.
    uint256 internal totalVoteSeconds;
    /// @notice Last timestamp when `totalVoteSeconds` was accrued.
    uint64 internal totalVoteSecondsLastAccrued;

    /// @notice Funded emissions not yet paid into pool reward schedules.
    uint256 internal emissionReserve;
    /// @notice Accrued emissions not yet assigned to any pool.
    uint256 internal unallocatedEmissions;
    /// @notice Current global Q32 emission rate.
    uint224 internal emissionRate;
    /// @notice Last timestamp when global emissions were accrued.
    uint64 internal emissionsLastAccrued;
    /// @notice Next unprocessed index in `emissionEventTimes`.
    uint256 internal nextEmissionEventIndex;
    /// @notice Sorted emission end times.
    uint64[] internal emissionEventTimes;
    /// @notice Global emission-rate decreases at each end time.
    mapping(uint64 => uint224) internal emissionRateDecreaseAt;

    /// @notice Emitted when stake is added.
    event StakeIncreased(address indexed owner, bytes32 indexed salt, uint64 indexed endTime, uint128 amount);
    /// @notice Emitted when expired stake is removed.
    event StakeDecreased(address indexed owner, bytes32 indexed salt, uint64 indexed endTime, uint128 amount);
    /// @notice Emitted when stake is moved between stake keys.
    event StakeMoved(
        address indexed owner, bytes32 indexed fromSalt, uint64 indexed fromEndTime, bytes32 toSalt, uint64 toEndTime
    );
    /// @notice Emitted after a stake's votes are updated.
    event Voted(bytes32 indexed stakeId);
    /// @notice Emitted when a swap accounts fees to voters.
    event PoolFeesAccounted(PoolId indexed poolId, uint128 amount0, uint128 amount1);
    /// @notice Emitted when accrued voter fees are claimed for a stake.
    event PoolFeesClaimed(
        bytes32 indexed stakeId, PoolId indexed poolId, address indexed recipient, uint128 amount0, uint128 amount1
    );
    /// @notice Emitted when a stake's active votes are reduced to current decayed voting power.
    event StakePoked(
        address indexed owner, bytes32 indexed salt, uint64 indexed endTime, uint256 previousWeight, uint256 nextWeight
    );
    /// @notice Emitted when global emissions are funded.
    event EmissionsFunded(address indexed funder, uint128 amount, uint224 rate, uint64 end);
    /// @notice Emitted when emissions are assigned to a pool.
    event PoolEmissionsTriggered(PoolId indexed poolId, uint224 amount, uint64 end);
    /// @notice Emitted when a pool reward stream is scheduled.
    event PoolRewarded(PoolId indexed poolId, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    /// @notice Emitted when an LP position claims reward tokens.
    event RewardsClaimed(
        PoolId indexed poolId, address indexed owner, PositionId indexed positionId, address recipient, uint256 amount
    );
    /// @notice Emitted when reward tokens are donated directly to current pool liquidity.
    event RewardsDonated(PoolId indexed poolId, uint128 amount);
    /// @notice Emitted when a pool's active swap fee changes.
    event PoolSwapFeeUpdated(PoolId indexed poolId, uint64 swapFee);

    /// @notice Thrown when a pool is initialized with a nonzero Core fee.
    error ZeroConfigFeeOnly();
    /// @notice Thrown when a swap attempts to bypass the forward-only swap path.
    error SwapMustHappenThroughForward();
    /// @notice Thrown when a vote payload or target pool is invalid.
    error InvalidVote();
    /// @notice Thrown when a global emission funding amount is zero.
    error EmissionAmountTooSmall();
    /// @notice Thrown when reward schedule timestamps are invalid.
    error InvalidTimestamps();
    /// @notice Thrown when a reward amount cannot fit in the supported token accounting width.
    error RewardAmountOverflow();
    /// @notice Thrown when a reward-rate delta exceeds the allowed bound.
    error MaxRateDeltaPerTime();
    /// @notice Thrown when reward accounting is requested for a pool not initialized for this extension.
    error PoolNotInitialized();
    /// @notice Thrown when a stake owner-only action is called by another address.
    error NotStakeOwner();
    /// @notice Thrown when a stake amount or timestamp is invalid.
    error InvalidStake();

    /// @notice Initializes the extension with Core and the immutable reward/stake token.
    /// @param core Ekubo Core contract.
    /// @param _stakeToken Token used for ve stakes and LP rewards.
    constructor(ICore core, address _stakeToken) BaseExtension(core) BaseForwardee(core) {
        stakeToken = _stakeToken;
        emissionsLastAccrued = uint64(block.timestamp);
        totalVoteSecondsLastAccrued = uint64(block.timestamp);
    }

    /// @notice Allows the extension to receive native-token voter fees.
    receive() external payable {}

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return ve33CallPoints();
    }

    /// @notice Validates and initializes extension state for a new pool.
    /// @dev Pools must use zero Core fee because the active fee is stored in `poolVoteStates`.
    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension) onlyCore {
        if (poolKey.config.fee() != 0) revert ZeroConfigFeeOnly();

        PoolId poolId = poolKey.toPoolId();
        uint64 defaultSwapFee = poolKey.config.isStableswap()
            ? defaultVeFeeForStableswapAmplification(poolKey.config.stableswapAmplification())
            : defaultVeFeeForTickSpacing(poolKey.config.concentratedTickSpacing());
        poolVoteStates[poolId].swapFee = defaultSwapFee;
        poolVoteStates[poolId].defaultSwapFee = defaultSwapFee;
        poolRewardState[poolId] = createVe33RewardPoolState(uint32(block.timestamp), 0);
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

    /// @notice Computes the current voting power for a lock.
    /// @dev Voting power decays linearly to zero at `stakeKey.endTime`.
    /// @param stakeKey Canonical stake key.
    /// @return power Current voting power.
    function _votingPower(StakeKey calldata stakeKey) private view returns (uint256 power) {
        if (block.timestamp >= stakeKey.endTime) return 0;

        unchecked {
            power =
                (uint256(stakeAmounts[stakeKey.owner][stakeKey.salt][stakeKey.endTime])
                        * (stakeKey.endTime - block.timestamp)) / MAX_STAKE_DURATION;
        }
    }

    /// @notice Replaces the votes for a lock.
    /// @dev `swapFees` are capped to the protocol maximum. Only `stakeKey.owner` may vote directly.
    /// @param stakeKey Stake whose votes are being updated.
    /// @param poolKeys Pools to vote on.
    /// @param weights Relative weights assigned to each pool.
    /// @param swapFees Explicit swap fee vote for each pool.
    function vote(
        StakeKey calldata stakeKey,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint64[] calldata swapFees
    ) external {
        if (stakeKey.owner != msg.sender) revert NotStakeOwner();
        _vote(stakeKey, poolKeys, weights, swapFees);
    }

    /// @notice Permissionlessly refreshes a stake's active votes to its current decayed voting power.
    /// @dev Accrues vote seconds and voter fees before reducing weights. Expired stakes are cleared.
    /// @param stakeKey Stake whose active votes are refreshed.
    /// @return previousWeight Total active vote weight before the poke.
    /// @return nextWeight Total active vote weight after the poke.
    function poke(StakeKey calldata stakeKey) external returns (uint256 previousWeight, uint256 nextWeight) {
        bytes32 stakeId = _stakeId(stakeKey.owner, stakeKey.salt, stakeKey.endTime);
        (previousWeight, nextWeight) = _pokeVotes(stakeId, _votingPower(stakeKey));
        emit StakePoked(stakeKey.owner, stakeKey.salt, stakeKey.endTime, previousWeight, nextWeight);
    }

    /// @notice Accumulates scheduled LP rewards into the pool reward-per-liquidity global value.
    /// @dev If the pool has no active in-range liquidity, accrued rewards are not assigned to LPs.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            Ve33RewardPoolState state = poolRewardState[poolId];

            if (state.ve33LastAccumulated() == 0) {
                if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
                state = createVe33RewardPoolState(uint32(block.timestamp), 0);
                poolRewardState[poolId] = state;
            }

            if (uint32(block.timestamp) == state.ve33LastAccumulated()) return;

            uint256 lastAccumulated = state.ve33RealLastAccumulated();
            uint256 time = lastAccumulated;
            uint256 rewardRate = state.ve33RewardRate();
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

            PoolState coreState = CORE.poolState(poolId);
            uint128 liquidity = coreState.liquidity();
            if (liquidity != 0 && poolKey.config.isStableswap()) {
                (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
                int32 tick = coreState.tick();
                if (tick < lower || tick >= upper) liquidity = 0;
            }
            if (rewardsAccrued != 0 && liquidity != 0) {
                rewardsGlobalPerLiquidity[poolId] += (rewardsAccrued << 128) / liquidity;
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
        } else if (callType == VE33_ADD_REWARDS) {
            (, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, PoolKey, uint64, uint64, uint224));
            result = abi.encode(_addRewards(poolKey, startTime, endTime, rewardRate));
        } else if (callType == VE33_STAKE) {
            (, bytes32 salt, uint64 endTime, uint128 amount) = abi.decode(data, (uint256, bytes32, uint64, uint128));
            result = abi.encode(_stake(original.addr(), salt, endTime, amount));
        } else if (callType == VE33_UNSTAKE) {
            (, bytes32 salt, uint64 endTime, uint128 amount) = abi.decode(data, (uint256, bytes32, uint64, uint128));
            result = abi.encode(_unstake(original.addr(), salt, endTime, amount));
        } else if (callType == VE33_MOVE_STAKE) {
            (, bytes32 fromSalt, uint64 fromEndTime, bytes32 toSalt, uint64 toEndTime, uint128 amount) =
                abi.decode(data, (uint256, bytes32, uint64, bytes32, uint64, uint128));
            result = abi.encode(_moveStake(original.addr(), fromSalt, fromEndTime, toSalt, toEndTime, amount));
        } else if (callType == VE33_CLAIM_POOL_FEES) {
            (, StakeKey memory stakeKey, PoolKey memory poolKey) = abi.decode(data, (uint256, StakeKey, PoolKey));
            if (stakeKey.owner != original.addr()) revert NotStakeOwner();
            (uint128 amount0, uint128 amount1) = _claimPoolFees(stakeKey, poolKey, original.addr());
            result = abi.encode(amount0, amount1);
        } else if (callType == VE33_FUND_EMISSIONS) {
            (, uint128 amount) = abi.decode(data, (uint256, uint128));
            (uint224 rate, uint64 end) = _fundEmissions(original.addr(), amount);
            result = abi.encode(rate, end);
        } else if (callType == VE33_TRIGGER_POOL_EMISSIONS) {
            (, PoolKey memory poolKey) = abi.decode(data, (uint256, PoolKey));
            result = abi.encode(_triggerPoolEmissions(poolKey));
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

            uint64 swapFee = poolVoteStates[poolId].swapFee;
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

    /// @notice Computes the canonical stake id.
    /// @param owner Locker representation that owns the stake.
    /// @param salt Caller-selected stake salt.
    /// @param endTime Stake expiry timestamp.
    /// @return stakeId Hash used for vote and fee accounting.
    function _stakeId(address owner, bytes32 salt, uint64 endTime) private pure returns (bytes32) {
        return EfficientHashLib.hash(uint256(uint160(owner)), uint256(salt), endTime);
    }

    /// @notice Validates that a new or moved-to stake is active and nonzero.
    /// @param endTime Proposed stake expiry timestamp.
    /// @param amount Amount being staked or moved.
    function _validateNewStake(uint64 endTime, uint128 amount) private view {
        if (amount == 0 || endTime <= block.timestamp || endTime > block.timestamp + MAX_STAKE_DURATION) {
            revert InvalidStake();
        }
    }

    /// @notice Adds stake and records the saved balance under this extension.
    /// @dev Does not transfer tokens; the calling stake representation settles the payment in the same Core lock.
    /// @param owner Locker representation that owns the stake.
    /// @param salt Stake salt.
    /// @param endTime Stake expiry timestamp.
    /// @param amount Amount of stake to add.
    /// @return staked Amount added to the stake.
    function _stake(address owner, bytes32 salt, uint64 endTime, uint128 amount) private returns (uint128 staked) {
        _validateNewStake(endTime, amount);

        staked = amount;
        bytes32 stakeId = _stakeId(owner, salt, endTime);
        _clearVotes(stakeId);
        stakeAmounts[owner][salt][endTime] += amount;
        _updateStakeSavedBalance(stakeId, int256(uint256(amount)));

        emit StakeIncreased(owner, salt, endTime, amount);
    }

    /// @notice Removes stake from an expired stake and records the saved-balance decrease.
    /// @dev Does not transfer tokens; the calling stake representation withdraws tokens from Core.
    /// @param owner Locker representation that owns the stake.
    /// @param salt Stake salt.
    /// @param endTime Stake expiry timestamp.
    /// @param amount Amount of stake to remove.
    /// @return unstaked Amount removed from the stake.
    function _unstake(address owner, bytes32 salt, uint64 endTime, uint128 amount) private returns (uint128 unstaked) {
        if (amount == 0 || block.timestamp < endTime) revert InvalidStake();

        uint128 currentAmount = stakeAmounts[owner][salt][endTime];
        if (amount > currentAmount) revert InvalidStake();

        unstaked = amount;
        bytes32 stakeId = _stakeId(owner, salt, endTime);
        _clearVotes(stakeId);
        stakeAmounts[owner][salt][endTime] = currentAmount - amount;
        _updateStakeSavedBalance(stakeId, -int256(uint256(amount)));

        emit StakeDecreased(owner, salt, endTime, amount);
    }

    /// @notice Moves stake between two stake keys for the same owner.
    /// @dev Used by wrappers to model extension by withdrawing one stake key and staking into another without transfers.
    /// @param owner Locker representation that owns both stake keys.
    /// @param fromSalt Source stake salt.
    /// @param fromEndTime Source stake expiry timestamp.
    /// @param toSalt Destination stake salt.
    /// @param toEndTime Destination stake expiry timestamp.
    /// @param amount Amount of stake to move.
    /// @return moved Amount moved between stake keys.
    function _moveStake(
        address owner,
        bytes32 fromSalt,
        uint64 fromEndTime,
        bytes32 toSalt,
        uint64 toEndTime,
        uint128 amount
    ) private returns (uint128 moved) {
        _validateNewStake(toEndTime, amount);

        uint128 currentAmount = stakeAmounts[owner][fromSalt][fromEndTime];
        if (amount > currentAmount) revert InvalidStake();

        moved = amount;
        bytes32 fromStakeId = _stakeId(owner, fromSalt, fromEndTime);
        bytes32 toStakeId = _stakeId(owner, toSalt, toEndTime);
        _clearVotes(fromStakeId);
        _clearVotes(toStakeId);
        stakeAmounts[owner][fromSalt][fromEndTime] = currentAmount - amount;
        stakeAmounts[owner][toSalt][toEndTime] += amount;
        _updateStakeSavedBalance(fromStakeId, -int256(uint256(amount)));
        _updateStakeSavedBalance(toStakeId, int256(uint256(amount)));

        emit StakeMoved(owner, fromSalt, fromEndTime, toSalt, toEndTime);
    }

    /// @notice Applies a stake's votes to pool accounting.
    /// @dev Clears old votes first. Duplicate pools, mismatched lengths, non-extension pools, and zero total weight revert.
    /// @param stakeKey Stake whose voting power is allocated.
    /// @param poolKeys Pools receiving votes.
    /// @param weights Relative weights for each pool.
    /// @param swapFees Explicit swap fee votes for each pool.
    function _vote(
        StakeKey calldata stakeKey,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint64[] memory swapFees
    ) private {
        if (poolKeys.length != weights.length || poolKeys.length != swapFees.length) {
            revert InvalidVote();
        }

        uint256 power = _votingPower(stakeKey);
        if (power == 0) revert InvalidVote();
        bytes32 stakeId = _stakeId(stakeKey.owner, stakeKey.salt, stakeKey.endTime);

        uint256 length = weights.length;
        uint256 totalWeight;
        for (uint256 i; i < length;) {
            totalWeight += weights[i];
            PoolId poolId = poolKeys[i].toPoolId();
            if (poolKeys[i].config.extension() != address(this) || poolKeys[i].config.fee() != 0) revert InvalidVote();
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

        _clearVotes(stakeId);
        for (uint256 i = _accrueTotalVoteSeconds(); i < length;) {
            uint256 weight = (power * weights[i]) / totalWeight;
            if (weight != 0) {
                PoolId poolId = poolKeys[i].toPoolId();
                uint64 swapFee = capFee(swapFees[i]);
                _accruePoolVoteSeconds(poolId);

                PoolVoteState storage poolState = poolVoteStates[poolId];
                VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];

                poolState.weight += weight;
                poolState.feeWeightSum += weight * swapFee;
                totalVoteWeight += weight;

                // Safe because a stake's allocated pool weight cannot exceed its uint128 staked amount.
                vePool.weight = uint128(weight);
                vePool.swapFee = swapFee;
                vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
                vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
                votedPools[stakeId].push(poolId);

                _updatePoolSwapFee(poolId);
            }
            unchecked {
                ++i;
            }
        }

        emit Voted(stakeId);
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
    /// @param stakeKey Stake claiming fees.
    /// @param poolKey Pool whose fees are claimed.
    /// @param recipient Account recorded in the claim event.
    /// @return amount0 Claimed token0 amount.
    /// @return amount1 Claimed token1 amount.
    function _claimPoolFees(StakeKey memory stakeKey, PoolKey memory poolKey, address recipient)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        bytes32 stakeId = _stakeId(stakeKey.owner, stakeKey.salt, stakeKey.endTime);
        _accrueVePoolFees(stakeId, poolId);

        VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];
        amount0 = uint128(vePool.accrued0);
        amount1 = uint128(vePool.accrued1);

        if (amount0 != 0 || amount1 != 0) {
            vePool.accrued0 = 0;
            vePool.accrued1 = 0;
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );
        }

        emit PoolFeesClaimed(stakeId, poolId, recipient, amount0, amount1);
    }

    /// @notice Funds global ve emissions for one emission duration.
    /// @dev Saves the funded amount in Core; the forwarding locker must pay `stakeToken` into Core.
    /// @param funder Account recorded in the funding event.
    /// @param amount Amount of `stakeToken` to add to the global emission stream.
    /// @return rate Added Q32 global emission rate.
    /// @return end Emission stream end timestamp.
    function _fundEmissions(address funder, uint128 amount) private returns (uint224 rate, uint64 end) {
        if (amount == 0) revert EmissionAmountTooSmall();

        rate = uint224(((uint256(amount) + _accrueEmissions()) << 32) / EMISSION_DURATION);

        end = uint64(block.timestamp + EMISSION_DURATION);
        emissionReserve += amount;
        emissionRate += rate;
        emissionRateDecreaseAt[end] += rate;
        emissionEventTimes.push(end);
        _updateEmissionReserveSavedBalance(int256(uint256(amount)));

        emit EmissionsFunded(funder, amount, rate, end);
    }

    /// @notice Assigns the pool's share of unallocated global emissions to LP rewards.
    /// @dev Share is based on the pool's accrued vote seconds over total accrued vote seconds.
    /// @param poolKey Pool receiving emissions.
    /// @return amount Emission amount scheduled for the pool.
    function _triggerPoolEmissions(PoolKey memory poolKey) private returns (uint224 amount) {
        if (poolKey.config.extension() != address(this)) revert PoolNotInitialized();

        PoolId poolId = poolKey.toPoolId();
        _accrueEmissions();
        _accruePoolVoteSeconds(poolId);

        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 poolSeconds = poolState.voteSeconds + _accrueTotalVoteSeconds();
        if (poolSeconds == 0 || totalVoteSeconds == 0 || unallocatedEmissions == 0 || emissionReserve == 0) {
            emit PoolEmissionsTriggered(poolId, 0, uint64(block.timestamp));
            return 0;
        }

        uint256 amount256 = (unallocatedEmissions * poolSeconds) / totalVoteSeconds;
        if (amount256 > emissionReserve) amount256 = emissionReserve;
        if (amount256 == 0) {
            emit PoolEmissionsTriggered(poolId, 0, uint64(block.timestamp));
            return 0;
        }

        unchecked {
            unallocatedEmissions -= amount256;
            totalVoteSeconds -= poolSeconds;
        }
        poolState.voteSeconds = 0;

        uint256 endTime = nextValidTime(block.timestamp, block.timestamp + EMISSION_DURATION - 1);
        uint256 duration = endTime - block.timestamp;
        uint224 rewardRate = uint224((amount256 << 32) / duration);

        amount = _addRewards(poolKey, 0, uint64(endTime), rewardRate);
        emissionReserve -= amount;
        if (amount != 0) _updateEmissionReserveSavedBalance(-int256(uint256(amount)));

        emit PoolEmissionsTriggered(poolId, amount, uint64(endTime));
    }

    /// @notice Schedules reward-token emissions for a pool.
    /// @dev Updates the reward reserve saved balance and the pool reward-rate schedule.
    /// @param poolKey Pool receiving rewards.
    /// @param startTime Stream start time, or zero for immediate scheduling.
    /// @param endTime Stream end time.
    /// @param rewardRate Q32 reward rate in tokens per second.
    /// @return amount Total token amount required for the schedule.
    function _addRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
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
                state.ve33LastAccumulated(), uint224(_addRewardRate(state.ve33RewardRate(), rewardRateDelta))
            );
        }

        _updateTime(poolId, endTime, -rewardRateDelta);

        emit PoolRewarded(poolId, startTime, endTime, rewardRate, amount);
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
            uint128 liquidity = CORE.poolState(poolId).liquidity();
            _updateRewardSavedBalance(int256(uint256(amount)));
            if (liquidity != 0) {
                unchecked {
                    rewardsGlobalPerLiquidity[poolId] += (uint256(amount) << 128) / liquidity;
                }
            }
        }

        emit RewardsDonated(poolId, amount);
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
    /// @dev Accrues voter fees first so already-earned fees remain claimable.
    /// @param stakeId Stake id whose votes are cleared.
    function _clearVotes(bytes32 stakeId) private {
        PoolId[] storage pools = votedPools[stakeId];
        uint256 length = pools.length;
        if (length == 0) return;

        for (uint256 i = _accrueTotalVoteSeconds(); i < length;) {
            PoolId poolId = pools[i];
            _accruePoolVoteSeconds(poolId);
            _accrueVePoolFees(stakeId, poolId);

            VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];
            uint256 weight = vePool.weight;
            if (weight != 0) {
                PoolVoteState storage poolState = poolVoteStates[poolId];
                poolState.weight -= weight;
                poolState.feeWeightSum -= weight * vePool.swapFee;
                totalVoteWeight -= weight;
                vePool.weight = 0;
                _updatePoolSwapFee(poolId);
            }
            unchecked {
                ++i;
            }
        }

        delete votedPools[stakeId];
    }

    /// @notice Reduces a stake's active vote weights to a target total weight.
    /// @dev Accrues historical vote seconds and voter fees before changing future weights.
    /// @param stakeId Stake id whose votes are refreshed.
    /// @param targetWeight Current decayed voting power for the stake.
    /// @return previousWeight Total active vote weight before refresh.
    /// @return nextWeight Total active vote weight after refresh.
    function _pokeVotes(bytes32 stakeId, uint256 targetWeight)
        private
        returns (uint256 previousWeight, uint256 nextWeight)
    {
        PoolId[] storage pools = votedPools[stakeId];
        uint256 length = pools.length;
        if (length == 0) return (0, 0);

        for (uint256 i = _accrueTotalVoteSeconds(); i < length;) {
            PoolId poolId = pools[i];
            _accruePoolVoteSeconds(poolId);
            _accrueVePoolFees(stakeId, poolId);
            previousWeight += vePoolPositions[stakeId][poolId].weight;
            unchecked {
                ++i;
            }
        }

        if (targetWeight >= previousWeight) return (previousWeight, previousWeight);
        nextWeight = targetWeight;

        if (targetWeight == 0) {
            for (uint256 i; i < length;) {
                PoolId poolId = pools[i];
                VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];
                uint256 oldWeight = vePool.weight;
                if (oldWeight != 0) {
                    PoolVoteState storage poolState = poolVoteStates[poolId];
                    poolState.weight -= oldWeight;
                    poolState.feeWeightSum -= oldWeight * vePool.swapFee;
                    totalVoteWeight -= oldWeight;
                    vePool.weight = 0;
                    _updatePoolSwapFee(poolId);
                }
                unchecked {
                    ++i;
                }
            }
            delete votedPools[stakeId];
        } else {
            uint256 remainingPreviousWeight = previousWeight;
            uint256 remainingNextWeight = targetWeight;

            for (uint256 i; i < length;) {
                PoolId poolId = pools[i];
                VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];
                uint256 oldWeight = vePool.weight;
                uint256 newWeight = oldWeight == remainingPreviousWeight
                    ? remainingNextWeight
                    : (oldWeight * targetWeight) / previousWeight;

                if (oldWeight != newWeight) {
                    PoolVoteState storage poolState = poolVoteStates[poolId];
                    poolState.weight = poolState.weight - oldWeight + newWeight;
                    poolState.feeWeightSum =
                        poolState.feeWeightSum - oldWeight * vePool.swapFee + newWeight * vePool.swapFee;
                    totalVoteWeight = totalVoteWeight - oldWeight + newWeight;
                    // Safe because targetWeight is current voting power, which cannot exceed the uint128 stake amount.
                    vePool.weight = uint128(newWeight);
                    _updatePoolSwapFee(poolId);
                }

                unchecked {
                    remainingPreviousWeight -= oldWeight;
                    remainingNextWeight -= newWeight;
                    ++i;
                }
            }
        }
    }

    /// @notice Accrues pool fees into a stake's per-pool voter position.
    /// @param stakeId Stake id receiving accrued fees.
    /// @param poolId Pool whose fee growth is accrued.
    function _accrueVePoolFees(bytes32 stakeId, PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        VePoolPosition storage vePool = vePoolPositions[stakeId][poolId];

        uint256 weight = vePool.weight;
        if (weight != 0) {
            unchecked {
                vePool.accrued0 += ((poolState.feeGrowth0X128 - vePool.feeGrowth0X128) * weight) >> 128;
                vePool.accrued1 += ((poolState.feeGrowth1X128 - vePool.feeGrowth1X128) * weight) >> 128;
            }
        }

        vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
        vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
    }

    /// @notice Accrues time-weighted vote seconds for one pool.
    /// @param poolId Pool whose vote seconds are accrued.
    function _accruePoolVoteSeconds(PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint64 lastAccrued = poolState.lastAccrued;
        if (lastAccrued == 0) {
            poolState.lastAccrued = uint64(block.timestamp);
        } else if (lastAccrued != block.timestamp) {
            unchecked {
                poolState.voteSeconds += poolState.weight * (block.timestamp - lastAccrued);
            }
            poolState.lastAccrued = uint64(block.timestamp);
        }
    }

    /// @notice Accrues global time-weighted vote seconds.
    /// @return zero Always zero, used as a compact loop initializer.
    function _accrueTotalVoteSeconds() private returns (uint256 zero) {
        uint64 lastAccrued = totalVoteSecondsLastAccrued;
        if (lastAccrued != block.timestamp) {
            unchecked {
                totalVoteSeconds += totalVoteWeight * (block.timestamp - lastAccrued);
            }
            totalVoteSecondsLastAccrued = uint64(block.timestamp);
        }
    }

    /// @notice Accrues global emissions into `unallocatedEmissions`.
    /// @return zero Always zero, used as a compact loop initializer.
    function _accrueEmissions() private returns (uint256 zero) {
        uint256 time = emissionsLastAccrued;
        uint224 rate = emissionRate;
        uint256 index = nextEmissionEventIndex;
        uint256 length = emissionEventTimes.length;

        while (index < length) {
            uint64 eventTime = emissionEventTimes[index];
            if (eventTime > block.timestamp) break;

            unchecked {
                unallocatedEmissions += (uint256(rate) * (eventTime - time)) >> 32;
            }
            rate -= emissionRateDecreaseAt[eventTime];
            delete emissionRateDecreaseAt[eventTime];
            time = eventTime;
            do {
                unchecked {
                    ++index;
                }
            } while (index < length && emissionEventTimes[index] == eventTime);
        }

        if (time != block.timestamp) {
            unchecked {
                unallocatedEmissions += (uint256(rate) * (block.timestamp - time)) >> 32;
            }
        }

        emissionRate = rate;
        emissionsLastAccrued = uint64(block.timestamp);
        if (index != nextEmissionEventIndex) nextEmissionEventIndex = index;
    }

    /// @notice Recomputes a pool's active swap fee from current voter weights.
    /// @param poolId Pool whose swap fee is updated.
    function _updatePoolSwapFee(PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint64 swapFee =
            poolState.weight == 0 ? poolState.defaultSwapFee : uint64(poolState.feeWeightSum / poolState.weight);
        poolState.swapFee = swapFee;
        emit PoolSwapFeeUpdated(poolId, swapFee);
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

    /// @notice Updates the saved balance for funded but unassigned emission tokens.
    /// @param delta Signed emission-reserve balance delta.
    function _updateEmissionReserveSavedBalance(int256 delta) private {
        CORE.updateSavedBalances(stakeToken, address(type(uint160).max), bytes32(uint256(1)), delta, 0);
    }

    /// @notice Updates the saved balance for staked tokens.
    /// @param stakeId Stake id whose saved balance changes.
    /// @param delta Signed staked-token balance delta.
    function _updateStakeSavedBalance(bytes32 stakeId, int256 delta) private {
        CORE.updateSavedBalances(stakeToken, address(type(uint160).max), stakeId, delta, 0);
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

    /// @notice Toggles whether a pool has a nonzero reward-rate delta at a valid time.
    /// @param poolId Pool whose bitmap changes.
    /// @param time Valid schedule time.
    function _flipTime(PoolId poolId, uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            initializedTimeBitmap[poolId][word] ^= uint256(1) << index;
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
