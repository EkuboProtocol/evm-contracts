// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {Ve33StorageLayout} from "../libraries/Ve33StorageLayout.sol";
import {ICore} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {isPowerOfFour} from "../math/isPowerOfFour.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
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
import {StorageSlot} from "../types/storageSlot.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "../types/feesPerLiquidity.sol";
import {VePoolFeeState, createVePoolFeeState} from "../types/vePoolFeeState.sol";
import {VePoolVote, createVePoolVote} from "../types/vePoolVote.sol";

// Forward call type for extension-mediated swaps.
uint256 constant VE33_SWAP = 0;
// Forward call type for claiming LP reward-token emissions.
uint256 constant VE33_CLAIM_REWARDS = 1;
// Forward call type for increasing a ve stake.
uint256 constant VE33_STAKE = 2;
// Forward call type for decreasing an expired ve stake.
uint256 constant VE33_UNSTAKE = 3;
// Forward call type for moving stake to a different stake id.
uint256 constant VE33_MOVE_STAKE = 4;
// Forward call type for claiming voter pool fees.
uint256 constant VE33_CLAIM_POOL_FEES = 5;
// Forward call type for scheduling global emissions.
uint256 constant VE33_SCHEDULE_EMISSIONS = 6;
// Forward call type for splitting stake while preserving the source vote.
uint256 constant VE33_SPLIT_STAKE = 7;

// Maximum absolute scheduled emission-rate delta allowed at one valid time.
uint256 constant VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA = type(uint192).max / MAX_NUM_VALID_TIMES;
// Maximum ve stake duration.
uint256 constant VE33_MAX_STAKE_DURATION = 4 * 365 days;
// Saved-balance salt for funded LP rewards.
bytes32 constant VE33_LP_REWARD_SAVED_BALANCE_ID = bytes32(0);

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

    /// @notice Token used for ve staking, global emissions, and LP rewards.
    address public immutable stakeToken;

    /// @notice Emitted when stake is added.
    event StakeIncreased(address owner, StakeId stakeId, uint128 amount);
    /// @notice Emitted when expired stake is removed.
    event StakeDecreased(address owner, StakeId stakeId, uint128 amount);
    /// @notice Emitted when stake is moved between stake keys.
    event StakeMoved(address owner, StakeId fromStakeId, StakeId toStakeId);
    /// @notice Emitted after a stake's vote is updated.
    event Voted(address owner, StakeId stakeId, PoolId poolId, uint128 weight, uint64 swapFee);
    /// @notice Emitted after a stake's vote is cleared.
    event VoteCleared(address owner, StakeId stakeId, PoolId poolId);
    /// @notice Emitted when a swap accounts fees to voters.
    event PoolFeesAccounted(PoolId poolId, uint128 amount0, uint128 amount1);
    /// @notice Emitted when accrued voter fees are claimed for a stake.
    event PoolFeesClaimed(
        PoolId poolId, address owner, StakeId stakeId, address recipient, uint128 amount0, uint128 amount1
    );
    /// @notice Emitted when a stake's active vote is reduced to current decayed voting power.
    event StakePoked(address owner, StakeId stakeId, uint256 previousWeight, uint256 nextWeight);
    /// @notice Emitted when global emissions are scheduled.
    event EmissionsScheduled(address funder, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    /// @notice Emitted when a pool accrues its share of global emissions to LP rewards.
    event PoolEmissionsAccrued(PoolId poolId, uint256 amount);
    /// @notice Emitted when an LP position claims reward tokens.
    event RewardsClaimed(PoolId poolId, address owner, PositionId positionId, address recipient, uint256 amount);

    /// @notice Thrown when a swap attempts to bypass the forward-only swap path.
    error SwapMustHappenThroughForward();
    /// @notice Thrown when a vote payload or target pool is invalid.
    error InvalidVote();
    /// @notice Thrown when a pool key is not valid for this extension.
    error InvalidPoolKey();
    /// @notice Thrown when a Ve33 pool uses a nonzero Core fee.
    error FeeMustBeZero();
    /// @notice Thrown when a concentrated Ve33 pool tick spacing is not a power of four.
    error TickSpacingMustBePowerOfFour();
    /// @notice Thrown when a global emission schedule amount is zero.
    error EmissionAmountTooSmall();
    /// @notice Thrown when emission schedule timestamps are invalid.
    error InvalidTimestamps();
    /// @notice Thrown when a reward amount cannot fit in the supported token accounting width.
    error RewardAmountOverflow();
    /// @notice Thrown when an emission-rate delta exceeds the allowed bound.
    error MaxRateDeltaPerTime();
    /// @notice Thrown when a stake amount or timestamp is invalid.
    error InvalidStake();

    /// @notice Initializes the extension with Core and the immutable reward/stake token.
    /// @param core Ekubo Core contract.
    /// @param _stakeToken Token used for ve stakes and LP rewards.
    constructor(ICore core, address _stakeToken) BaseExtension(core) BaseForwardee(core) {
        stakeToken = _stakeToken;
        _setEmissionRateAndLastAccrued({rate: 0, lastAccrued: uint64(block.timestamp)});
    }

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return ve33CallPoints();
    }

    /// @notice Validates extension-specific pool configuration before Core initializes a new pool.
    /// @dev Pools must use zero Core fee because the active fee is stored in Ve33 pool vote state.
    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension) onlyCore {
        checkValidPoolKey(poolKey);
    }

    /// @notice Initializes extension reward state after Core initializes a new pool.
    function afterInitializePool(address, PoolKey memory poolKey, int32, SqrtRatio)
        external
        override(BaseExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        _accumulatePoolRewards(poolId, CORE.poolState(poolId).liquidity());
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
            power = uint128(
                (uint256(_stakeAmount(owner, stakeId)) * (endTime - block.timestamp)) / VE33_MAX_STAKE_DURATION
            );
        }
    }

    /// @notice Checks that a pool key is configured for Ve33 accounting.
    /// @dev Ve33 pools must use this extension, zero Core fee, and power-of-four concentrated tick spacing.
    function checkValidPoolKey(PoolKey memory poolKey) private view {
        if (poolKey.config.fee() != 0) revert FeeMustBeZero();
        if (poolKey.config.isConcentrated()) {
            uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
            if (!isPowerOfFour(tickSpacing)) revert TickSpacingMustBePowerOfFour();
        }
        if (poolKey.config.extension() != address(this)) revert InvalidPoolKey();
    }

    function _stakeAmount(address owner, StakeId stakeId) private view returns (uint128 amount) {
        amount = uint128(uint256(Ve33StorageLayout.stakeAmountSlot(owner, stakeId).load()));
    }

    function _setStakeAmount(address owner, StakeId stakeId, uint128 amount) private {
        Ve33StorageLayout.stakeAmountSlot(owner, stakeId).store(bytes32(uint256(amount)));
    }

    function _votedPoolId(address owner, StakeId stakeId) private view returns (PoolId poolId) {
        poolId = PoolId.wrap(Ve33StorageLayout.votedPoolIdSlot(owner, stakeId).load());
    }

    function _setVotedPoolId(address owner, StakeId stakeId, PoolId poolId) private {
        Ve33StorageLayout.votedPoolIdSlot(owner, stakeId).store(PoolId.unwrap(poolId));
    }

    function _vePoolVote(address owner, StakeId stakeId) private view returns (VePoolVote veVote) {
        veVote = VePoolVote.wrap(Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).load());
    }

    function _setVePoolVote(address owner, StakeId stakeId, VePoolVote veVote) private {
        Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).store(VePoolVote.unwrap(veVote));
    }

    function _deleteVePoolVote(address owner, StakeId stakeId) private {
        Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).store(bytes32(0));
    }

    function _vePoolFeeGrowthSnapshot(address owner, StakeId stakeId)
        private
        view
        returns (FeesPerLiquidity memory feeGrowthSnapshot)
    {
        StorageSlot slot = Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId);
        (bytes32 value0, bytes32 value1) = slot.loadTwo();
        feeGrowthSnapshot.value0 = uint256(value0);
        feeGrowthSnapshot.value1 = uint256(value1);
    }

    function _setVePoolFeeGrowthSnapshot(address owner, StakeId stakeId, FeesPerLiquidity memory feeGrowthSnapshot)
        private
    {
        Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId)
            .storeTwo(bytes32(feeGrowthSnapshot.value0), bytes32(feeGrowthSnapshot.value1));
    }

    function _deleteVePoolFeeGrowthSnapshot(address owner, StakeId stakeId) private {
        Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId).storeTwo(bytes32(0), bytes32(0));
    }

    function _positionRewardsSnapshotPerLiquidity(PoolId poolId, address owner, PositionId positionId)
        private
        view
        returns (uint256)
    {
        return uint256(Ve33StorageLayout.positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId).load());
    }

    function _setPositionRewardsSnapshotPerLiquidity(
        PoolId poolId,
        address owner,
        PositionId positionId,
        uint256 snapshot
    ) private {
        Ve33StorageLayout.positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId).store(bytes32(snapshot));
    }

    function _tickRewardsOutsidePerLiquidity(PoolId poolId, int32 tick) private view returns (uint256) {
        return uint256(Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick).load());
    }

    function _setTickRewardsOutsidePerLiquidity(PoolId poolId, int32 tick, uint256 value) private {
        Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick).store(bytes32(value));
    }

    function _poolEmissionGrowthGlobalX128Snapshot(PoolId poolId) private view returns (uint256) {
        return uint256(Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId).load());
    }

    function _setPoolEmissionGrowthGlobalX128Snapshot(PoolId poolId, uint256 value) private {
        Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId).store(bytes32(value));
    }

    function _poolFeeState(PoolId poolId) private view returns (VePoolFeeState) {
        return VePoolFeeState.wrap(Ve33StorageLayout.poolFeeStateSlot(poolId).load());
    }

    function _setPoolFeeState(PoolId poolId, uint192 feeWeightSum, uint128 totalWeight) private {
        uint64 swapFee;
        assembly ("memory-safe") {
            swapFee := div(feeWeightSum, totalWeight)
        }
        Ve33StorageLayout.poolFeeStateSlot(poolId)
            .store(VePoolFeeState.unwrap(createVePoolFeeState(feeWeightSum, swapFee)));
    }

    function _poolTotalWeight(PoolId poolId) private view returns (uint128) {
        return uint128(uint256(Ve33StorageLayout.poolTotalWeightSlot(poolId).load()));
    }

    function _setPoolTotalWeight(PoolId poolId, uint128 totalWeight) private {
        Ve33StorageLayout.poolTotalWeightSlot(poolId).store(bytes32(uint256(totalWeight)));
    }

    function _poolFeeGrowth(PoolId poolId) private view returns (FeesPerLiquidity memory feeGrowth) {
        StorageSlot slot = Ve33StorageLayout.poolFeeGrowthSlot(poolId);
        (bytes32 value0, bytes32 value1) = slot.loadTwo();
        feeGrowth.value0 = uint256(value0);
        feeGrowth.value1 = uint256(value1);
    }

    function _setPoolFeeGrowth(PoolId poolId, FeesPerLiquidity memory feeGrowth) private {
        Ve33StorageLayout.poolFeeGrowthSlot(poolId).storeTwo(bytes32(feeGrowth.value0), bytes32(feeGrowth.value1));
    }

    function _rewardsGlobalPerLiquidity(PoolId poolId) private view returns (uint256) {
        return uint256(Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId).load());
    }

    function _setRewardsGlobalPerLiquidity(PoolId poolId, uint256 value) private {
        Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId).store(bytes32(value));
    }

    function _emissionRateDeltaAtTime(uint64 time) private view returns (int256) {
        return int256(uint256(Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time).load()));
    }

    function _setEmissionRateDeltaAtTime(uint64 time, int256 value) private {
        Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time).store(bytes32(uint256(value)));
    }

    function _emissionInitializedTimeBitmap(uint256 word) private view returns (Bitmap) {
        return Bitmap.wrap(uint256(Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word).load()));
    }

    function _setEmissionInitializedTimeBitmap(uint256 word, Bitmap bitmap) private {
        Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word).store(bytes32(Bitmap.unwrap(bitmap)));
    }

    function _totalVoteWeight() private view returns (uint128) {
        return uint128(uint256(Ve33StorageLayout.totalVoteWeightSlot().load()));
    }

    function _setTotalVoteWeight(uint128 weight) private {
        Ve33StorageLayout.totalVoteWeightSlot().store(bytes32(uint256(weight)));
    }

    function _emissionGrowthGlobalX128() private view returns (uint256) {
        return uint256(Ve33StorageLayout.emissionGrowthGlobalX128Slot().load());
    }

    function _setEmissionGrowthGlobalX128(uint256 value) private {
        Ve33StorageLayout.emissionGrowthGlobalX128Slot().store(bytes32(value));
    }

    function _emissionRateAndLastAccrued() private view returns (uint192 rate, uint64 lastAccrued) {
        uint256 packed = uint256(Ve33StorageLayout.emissionRateAndLastAccruedSlot().load());
        rate = uint192(packed);
        lastAccrued = uint64(packed >> 192);
    }

    function _setEmissionRateAndLastAccrued(uint192 rate, uint64 lastAccrued) private {
        Ve33StorageLayout.emissionRateAndLastAccruedSlot().store(bytes32(uint256(rate) | (uint256(lastAccrued) << 192)));
    }

    /// @notice Replaces the vote for a stake owned by the caller.
    /// @dev The stake's full current voting power is assigned to `poolKey`.
    /// @param stakeId Stake whose votes are being updated.
    /// @param poolKey Pool receiving the stake's full active voting power.
    /// @param swapFee Explicit swap fee vote for the pool.
    function vote(StakeId stakeId, PoolKey calldata poolKey, uint64 swapFee) external {
        _vote(msg.sender, stakeId, poolKey, swapFee);
    }

    /// @notice Clears the active vote for a stake owned by the caller.
    /// @dev Pending unclaimed voter fees for the stake's current pool are discarded.
    /// @param stakeId Stake whose vote is cleared.
    function clearVote(StakeId stakeId) external {
        _clearVotes(msg.sender, stakeId);
    }

    /// @notice Permissionlessly refreshes a stake's active vote to its current decayed voting power.
    /// @dev Accrues reward and voter-fee accounting before reducing weights. Expired stakes are cleared.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake whose active vote is refreshed.
    /// @return previousWeight Total active vote weight before the poke.
    /// @return nextWeight Total active vote weight after the poke.
    function poke(address owner, StakeId stakeId) external returns (uint256 previousWeight, uint256 nextWeight) {
        (previousWeight, nextWeight) = _pokeVotes(owner, stakeId, _votingPower(owner, stakeId));
        emit StakePoked(owner, stakeId, previousWeight, nextWeight);
    }

    /// @notice Accumulates global emissions into the pool reward-per-liquidity global value.
    /// @dev If the pool has no liquidity, accrued emissions are not assigned to LPs.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        PoolId poolId = poolKey.toPoolId();
        PoolState coreState = CORE.poolState(poolId);
        checkValidPoolKey(poolKey);

        _accumulatePoolRewards(poolId, coreState.liquidity());
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
        } else if (callType == VE33_SPLIT_STAKE) {
            (, StakeId fromStakeId, StakeId toStakeId, uint128 amount) =
                abi.decode(data, (uint256, StakeId, StakeId, uint128));
            result = abi.encode(_splitStake(original.addr(), fromStakeId, toStakeId, amount));
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

            uint64 swapFee = _poolFeeState(poolId).swapFee();
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
            uint256 rewardsInsidePerLiquidity = poolKey.config.isStableswap()
                ? _rewardsGlobalPerLiquidity(poolId)
                : _getRewardsInsidePerLiquidity(poolId, tick, positionId.tickLower(), positionId.tickUpper());
            uint256 snapshot = _positionRewardsSnapshotPerLiquidity(poolId, owner, positionId);
            uint256 amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

            if (poolKey.config.isConcentrated()) {
                _updateTickRewardsPerLiquidityOutside(poolId, tick, positionId.tickLower(), liquidityDelta);
                _updateTickRewardsPerLiquidityOutside(poolId, tick, positionId.tickUpper(), liquidityDelta);
            }

            if (liquidityNext == 0) {
                _setPositionRewardsSnapshotPerLiquidity(poolId, owner, positionId, 0);
            } else {
                uint256 rewardsInsideNextPerLiquidity = poolKey.config.isStableswap()
                    ? _rewardsGlobalPerLiquidity(poolId)
                    : _getRewardsInsidePerLiquidity(poolId, tick, positionId.tickLower(), positionId.tickUpper());
                unchecked {
                    _setPositionRewardsSnapshotPerLiquidity(
                        poolId, owner, positionId, rewardsInsideNextPerLiquidity - ((amount << 128) / liquidityNext)
                    );
                }
            }
        }
    }

    /// @notice Validates that a new or moved-to stake is active and nonzero.
    /// @param stakeId Proposed stake id.
    /// @param amount Amount being staked or moved.
    function _validateNewStake(StakeId stakeId, uint128 amount) private view {
        uint64 endTime = stakeId.endTime();
        if (amount == 0 || endTime <= block.timestamp || endTime > block.timestamp + VE33_MAX_STAKE_DURATION) {
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
        nextAmount = _stakeAmount(owner, stakeId) + amount;
        _setStakeAmount(owner, stakeId, nextAmount);
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), _stakeSavedBalanceId(owner, stakeId), int256(uint256(amount)), 0
        );

        emit StakeIncreased(owner, stakeId, amount);
    }

    /// @notice Removes stake from an expired stake and records the saved-balance decrease.
    /// @dev Does not transfer tokens; the calling stake representation withdraws tokens from Core.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id.
    /// @return unstaked Amount removed from the stake.
    function _unstake(address owner, StakeId stakeId) private returns (uint128 unstaked) {
        unstaked = _stakeAmount(owner, stakeId);
        if (unstaked == 0) return 0;

        uint64 endTime = stakeId.endTime();
        if (block.timestamp < endTime) revert InvalidStake();

        _clearVotes(owner, stakeId);
        _setStakeAmount(owner, stakeId, 0);
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), _stakeSavedBalanceId(owner, stakeId), -int256(uint256(unstaked)), 0
        );

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

        uint128 currentAmount = _stakeAmount(owner, fromStakeId);
        if (amount > currentAmount) revert InvalidStake();

        _clearVotes(owner, fromStakeId);
        _clearVotes(owner, toStakeId);
        _setStakeAmount(owner, fromStakeId, currentAmount - amount);
        nextAmount = _stakeAmount(owner, toStakeId) + amount;
        _setStakeAmount(owner, toStakeId, nextAmount);
        CORE.updateSavedBalances(
            stakeToken,
            address(type(uint160).max),
            _stakeSavedBalanceId(owner, fromStakeId),
            -int256(uint256(amount)),
            0
        );
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), _stakeSavedBalanceId(owner, toStakeId), int256(uint256(amount)), 0
        );

        emit StakeMoved(owner, fromStakeId, toStakeId);
    }

    /// @notice Splits stake into a new stake key for the same owner.
    /// @dev The source stake keeps its vote; only its active weight is resized to the reduced voting power.
    /// @param owner Locker representation that owns both stake keys.
    /// @param fromStakeId Source stake id.
    /// @param toStakeId Destination stake id.
    /// @param amount Amount of stake to split into the destination key.
    /// @return nextAmount Destination stake amount after the split.
    function _splitStake(address owner, StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        private
        returns (uint128 nextAmount)
    {
        _validateNewStake(toStakeId, amount);
        if (StakeId.unwrap(fromStakeId) == StakeId.unwrap(toStakeId)) revert InvalidStake();

        uint128 currentAmount = _stakeAmount(owner, fromStakeId);
        if (amount >= currentAmount) revert InvalidStake();

        _clearVotes(owner, toStakeId);
        _setStakeAmount(owner, fromStakeId, currentAmount - amount);
        nextAmount = _stakeAmount(owner, toStakeId) + amount;
        _setStakeAmount(owner, toStakeId, nextAmount);
        CORE.updateSavedBalances(
            stakeToken,
            address(type(uint160).max),
            _stakeSavedBalanceId(owner, fromStakeId),
            -int256(uint256(amount)),
            0
        );
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), _stakeSavedBalanceId(owner, toStakeId), int256(uint256(amount)), 0
        );
        _pokeVotes(owner, fromStakeId, _votingPower(owner, fromStakeId));

        emit StakeMoved(owner, fromStakeId, toStakeId);
    }

    /// @notice Applies a stake's vote to pool accounting.
    /// @dev Clears the previous vote first. Invalid pools and zero voting power revert.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake whose voting power is allocated.
    /// @param poolKey Pool receiving the stake's full active voting power.
    /// @param swapFee Explicit swap fee vote for the pool.
    function _vote(address owner, StakeId stakeId, PoolKey calldata poolKey, uint64 swapFee) private {
        uint128 power = _votingPower(owner, stakeId);
        if (power == 0) revert InvalidVote();

        checkValidPoolKey(poolKey);

        _clearVotes(owner, stakeId);

        PoolId poolId = poolKey.toPoolId();
        _accumulatePoolRewards(poolId, CORE.poolState(poolId).liquidity());

        uint128 totalWeight = _poolTotalWeight(poolId);
        uint192 feeWeightSum = _poolFeeState(poolId).feeWeightSum();

        unchecked {
            totalWeight += power;
            feeWeightSum += uint192(uint256(power) * swapFee);
            _setTotalVoteWeight(_totalVoteWeight() + power);
        }
        _setPoolTotalWeight(poolId, totalWeight);
        _setPoolFeeState(poolId, feeWeightSum, totalWeight);

        _setVotedPoolId(owner, stakeId, poolId);
        _setVePoolVote(owner, stakeId, createVePoolVote(power, swapFee, uint64(block.timestamp)));
        _setVePoolFeeGrowthSnapshot(owner, stakeId, _poolFeeGrowth(poolId));

        emit Voted(owner, stakeId, poolId, power, swapFee);
    }

    /// @notice Adds swap fees to a pool's voter fee-growth accumulators.
    /// @param poolId Pool receiving fees.
    /// @param amount0 Token0 fee amount.
    /// @param amount1 Token1 fee amount.
    function _accountPoolFees(PoolId poolId, uint128 amount0, uint128 amount1) private {
        uint128 weight = _poolTotalWeight(poolId);
        if (weight != 0) {
            FeesPerLiquidity memory feeGrowthDelta =
                feesPerLiquidityFromAmounts({amount0: amount0, amount1: amount1, liquidity: weight});
            FeesPerLiquidity memory feeGrowth = _poolFeeGrowth(poolId);
            unchecked {
                feeGrowth.value0 += feeGrowthDelta.value0;
                feeGrowth.value1 += feeGrowthDelta.value1;
            }
            _setPoolFeeGrowth(poolId, feeGrowth);
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
        VePoolVote veVote = _vePoolVote(owner, stakeId);
        if (veVote.weight() == 0 || PoolId.unwrap(_votedPoolId(owner, stakeId)) != PoolId.unwrap(poolId)) {
            emit PoolFeesClaimed(poolId, owner, stakeId, recipient, 0, 0);
            return (0, 0);
        }

        FeesPerLiquidity memory feeGrowth = _poolFeeGrowth(poolId);
        FeesPerLiquidity memory feeGrowthSnapshot = _vePoolFeeGrowthSnapshot(owner, stakeId);
        (amount0, amount1) = veVote.fees(feeGrowth, feeGrowthSnapshot);
        _setVePoolFeeGrowthSnapshot(owner, stakeId, feeGrowth);

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
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), VE33_LP_REWARD_SAVED_BALANCE_ID, int256(uint256(amount)), 0
        );

        int256 rewardRateDelta = int256(uint256(rewardRate));
        if (startTime > block.timestamp) {
            _updateEmissionTime(startTime, rewardRateDelta);
        } else {
            (uint192 rate, uint64 lastAccrued) = _emissionRateAndLastAccrued();
            _setEmissionRateAndLastAccrued(uint192(_addEmissionRate(rate, rewardRateDelta)), lastAccrued);
        }

        _updateEmissionTime(endTime, -rewardRateDelta);

        emit EmissionsScheduled(funder, startTime, endTime, rewardRate, amount);
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
        uint256 snapshot = _positionRewardsSnapshotPerLiquidity(poolId, owner, positionId);

        uint256 rewardsInsidePerLiquidity = poolKey.config.isStableswap()
            ? _rewardsGlobalPerLiquidity(poolId)
            : _getRewardsInsidePerLiquidity(
                poolId, CORE.poolState(poolId).tick(), positionId.tickLower(), positionId.tickUpper()
            );
        amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

        _setPositionRewardsSnapshotPerLiquidity(
            poolId, owner, positionId, liquidity == 0 ? 0 : rewardsInsidePerLiquidity
        );

        if (amount > type(uint128).max) revert RewardAmountOverflow();

        if (amount != 0) {
            uint128 amountUint128 = uint128(amount);
            CORE.updateSavedBalances(
                stakeToken,
                address(type(uint160).max),
                VE33_LP_REWARD_SAVED_BALANCE_ID,
                -int256(uint256(amountUint128)),
                0
            );
        }

        emit RewardsClaimed(poolId, owner, positionId, recipient, amount);
    }

    /// @notice Clears the active vote for a stake.
    /// @dev Pending voter fees are discarded when a vote is fully cleared, matching zero-liquidity Core positions.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose votes are cleared.
    function _clearVotes(address owner, StakeId stakeId) private {
        PoolId poolId = _votedPoolId(owner, stakeId);
        VePoolVote veVote = _vePoolVote(owner, stakeId);
        uint128 weight = veVote.weight();
        if (weight == 0) return;

        _accumulatePoolRewards(poolId, CORE.poolState(poolId).liquidity());

        (veVote,) = _setVePoolVoteWeight(
            _poolFeeGrowth(poolId), _vePoolFeeGrowthSnapshot(owner, stakeId), veVote, 0, uint64(block.timestamp)
        );
        uint128 totalWeight = _poolTotalWeight(poolId);
        uint192 feeWeightSum = _poolFeeState(poolId).feeWeightSum();
        unchecked {
            totalWeight -= weight;
            feeWeightSum -= uint192(uint256(weight) * veVote.swapFee());
            _setTotalVoteWeight(_totalVoteWeight() - weight);
        }
        _setPoolTotalWeight(poolId, totalWeight);
        _setPoolFeeState(poolId, feeWeightSum, totalWeight);

        _setVotedPoolId(owner, stakeId, PoolId.wrap(bytes32(0)));
        _deleteVePoolVote(owner, stakeId);
        _deleteVePoolFeeGrowthSnapshot(owner, stakeId);
        emit VoteCleared(owner, stakeId, poolId);
    }

    /// @notice Reduces a stake's active vote weight to a target weight.
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
        PoolId poolId = _votedPoolId(owner, stakeId);
        VePoolVote veVote = _vePoolVote(owner, stakeId);
        previousWeight = veVote.weight();
        if (previousWeight == 0) return (0, 0);

        _accumulatePoolRewards(poolId, CORE.poolState(poolId).liquidity());

        if (targetWeight >= previousWeight) return (previousWeight, previousWeight);
        nextWeight = targetWeight;

        if (targetWeight == 0) {
            (veVote,) = _setVePoolVoteWeight(
                _poolFeeGrowth(poolId), _vePoolFeeGrowthSnapshot(owner, stakeId), veVote, 0, uint64(block.timestamp)
            );
            uint128 totalWeight = _poolTotalWeight(poolId);
            uint192 feeWeightSum = _poolFeeState(poolId).feeWeightSum();
            unchecked {
                totalWeight -= uint128(previousWeight);
                feeWeightSum -= uint192(previousWeight * veVote.swapFee());
                _setTotalVoteWeight(_totalVoteWeight() - uint128(previousWeight));
            }
            _setPoolTotalWeight(poolId, totalWeight);
            _setPoolFeeState(poolId, feeWeightSum, totalWeight);
            _setVotedPoolId(owner, stakeId, PoolId.wrap(bytes32(0)));
            _deleteVePoolVote(owner, stakeId);
            _deleteVePoolFeeGrowthSnapshot(owner, stakeId);
            emit VoteCleared(owner, stakeId, poolId);
        } else {
            uint128 oldWeight = uint128(previousWeight);
            uint128 newWeight = uint128(targetWeight);
            uint128 totalWeight = _poolTotalWeight(poolId);
            uint192 feeWeightSum = _poolFeeState(poolId).feeWeightSum();
            FeesPerLiquidity memory feeGrowthSnapshot;
            (veVote, feeGrowthSnapshot) = _setVePoolVoteWeight(
                _poolFeeGrowth(poolId),
                _vePoolFeeGrowthSnapshot(owner, stakeId),
                veVote,
                newWeight,
                uint64(block.timestamp)
            );
            unchecked {
                totalWeight = totalWeight - oldWeight + newWeight;
                feeWeightSum = feeWeightSum - uint192(uint256(oldWeight) * veVote.swapFee())
                    + uint192(uint256(newWeight) * veVote.swapFee());
                _setTotalVoteWeight(_totalVoteWeight() - oldWeight + newWeight);
            }
            _setPoolTotalWeight(poolId, totalWeight);
            _setPoolFeeState(poolId, feeWeightSum, totalWeight);
            _setVePoolVote(owner, stakeId, veVote);
            _setVePoolFeeGrowthSnapshot(owner, stakeId, feeGrowthSnapshot);
        }
    }

    /// @notice Changes a stake's pool vote weight while preserving fees already accrued under the old weight.
    /// @dev Mirrors Core position fee snapshot adjustment. If `nextWeight` is zero, pending fees are discarded.
    /// @param feeGrowth Pool fee growth state.
    /// @param feeGrowthSnapshot Stake's pool fee-growth snapshot.
    /// @param veVote Stake's pool vote position.
    /// @param nextWeight New vote weight for the stake in this pool.
    function _setVePoolVoteWeight(
        FeesPerLiquidity memory feeGrowth,
        FeesPerLiquidity memory feeGrowthSnapshot,
        VePoolVote veVote,
        uint128 nextWeight,
        uint64 timestamp
    ) private pure returns (VePoolVote nextVeVote, FeesPerLiquidity memory nextFeeGrowthSnapshot) {
        nextVeVote = veVote;
        nextFeeGrowthSnapshot = feeGrowthSnapshot;
        if (nextWeight == 0) {
            nextVeVote = createVePoolVote(0, veVote.swapFee(), timestamp);
            nextFeeGrowthSnapshot.value0 = feeGrowth.value0;
            nextFeeGrowthSnapshot.value1 = feeGrowth.value1;
        } else {
            (uint128 amount0, uint128 amount1) = veVote.fees(feeGrowth, feeGrowthSnapshot);
            nextVeVote = createVePoolVote(nextWeight, veVote.swapFee(), timestamp);
            FeesPerLiquidity memory feeGrowthDelta =
                feesPerLiquidityFromAmounts({amount0: amount0, amount1: amount1, liquidity: nextWeight});
            unchecked {
                nextFeeGrowthSnapshot.value0 = feeGrowth.value0 - feeGrowthDelta.value0;
                nextFeeGrowthSnapshot.value1 = feeGrowth.value1 - feeGrowthDelta.value1;
            }
        }
    }

    /// @notice Accumulates global emissions into one pool's LP reward growth.
    /// @param poolId Pool whose reward state is being accumulated.
    /// @param liquidity Current Core pool liquidity.
    function _accumulatePoolRewards(PoolId poolId, uint128 liquidity) private {
        unchecked {
            _accrueEmissions();

            uint256 emissionRewardsAccrued = _poolEmissionRewardsAccrued(poolId);

            if (emissionRewardsAccrued != 0) {
                if (liquidity != 0) {
                    if (emissionRewardsAccrued > type(uint128).max) revert RewardAmountOverflow();
                    _setRewardsGlobalPerLiquidity(
                        poolId, _rewardsGlobalPerLiquidity(poolId) + ((emissionRewardsAccrued << 128) / liquidity)
                    );
                }

                emit PoolEmissionsAccrued(poolId, emissionRewardsAccrued);
            }
        }
    }

    /// @notice Accrues a pool's share of global emissions since its last pool-emission snapshot.
    /// @param poolId Pool whose emission share is accrued.
    /// @return amount Amount of stake-token emissions assigned to the pool.
    function _poolEmissionRewardsAccrued(PoolId poolId) private returns (uint256 amount) {
        uint256 emissionGrowthGlobalX128_ = _emissionGrowthGlobalX128();
        uint256 snapshot = _poolEmissionGrowthGlobalX128Snapshot(poolId);
        if (snapshot != emissionGrowthGlobalX128_) {
            _setPoolEmissionGrowthGlobalX128Snapshot(poolId, emissionGrowthGlobalX128_);

            uint128 weight = _poolTotalWeight(poolId);
            if (weight != 0) {
                unchecked {
                    amount = FixedPointMathLib.fullMulDivN(emissionGrowthGlobalX128_ - snapshot, weight, 128);
                }
            }
        }
    }

    /// @notice Accrues global emissions into global emission growth.
    function _accrueEmissions() private {
        (uint192 rate, uint64 lastAccrued) = _emissionRateAndLastAccrued();
        if (lastAccrued == block.timestamp) return;

        uint256 time = lastAccrued;
        uint256 emissionGrowthGlobalX128_ = _emissionGrowthGlobalX128();

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) = _searchForNextEmissionTime(lastAccrued, time, block.timestamp);

            uint128 weight = _totalVoteWeight();
            uint256 amount;
            unchecked {
                amount = (uint256(rate) * (eventTime - time)) >> 32;
            }
            if (weight != 0) {
                emissionGrowthGlobalX128_ += FixedPointMathLib.fullMulDiv(amount, 1 << 128, weight);
            }
            if (initialized) {
                rate = uint192(_addEmissionRate(rate, _emissionRateDeltaAtTime(uint64(eventTime))));
                _setEmissionRateDeltaAtTime(uint64(eventTime), 0);
                _flipEmissionTime(eventTime);
            }
            time = eventTime;
        }

        _setEmissionGrowthGlobalX128(emissionGrowthGlobalX128_);
        _setEmissionRateAndLastAccrued(rate, uint64(block.timestamp));
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

        if (poolKey.config.isStableswap()) return;

        uint256 rewardsGlobalPerLiquidity_ = _rewardsGlobalPerLiquidity(poolId);

        uint32 tickSpacing = poolKey.config.concentratedTickSpacing();

        bool priceIncreasing = tickAfter > tickBefore;
        if (!priceIncreasing) {
            int32 tick = tickBefore;
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.prevInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (!initialized || tick <= tickAfter) break;
                unchecked {
                    _setTickRewardsOutsidePerLiquidity(
                        poolId, tick, rewardsGlobalPerLiquidity_ - _tickRewardsOutsidePerLiquidity(poolId, tick)
                    );
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
                    _setTickRewardsOutsidePerLiquidity(
                        poolId, tick, rewardsGlobalPerLiquidity_ - _tickRewardsOutsidePerLiquidity(poolId, tick)
                    );
                }
            }
        }
    }

    /// @notice Computes the Core saved-balance id for a staked token balance.
    function _stakeSavedBalanceId(address owner, StakeId stakeId) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(0x20, stakeId)
            result := keccak256(0x0c, 0x34)
        }
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
        uint256 lower = _tickRewardsOutsidePerLiquidity(poolId, tickLower);
        uint256 upper = _tickRewardsOutsidePerLiquidity(poolId, tickUpper);

        unchecked {
            if (tick < tickLower) {
                rewardsInsidePerLiquidity = lower - upper;
            } else if (tick < tickUpper) {
                rewardsInsidePerLiquidity = _rewardsGlobalPerLiquidity(poolId) - upper - lower;
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
            _setTickRewardsOutsidePerLiquidity(poolId, tick, 0);
            if (liquidityNetNext != 0) {
                _setTickRewardsOutsidePerLiquidity(
                    poolId, tick, tickCurrent >= tick ? _rewardsGlobalPerLiquidity(poolId) : 0
                );
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
    /// @param rewardRate Current emission rate.
    /// @param delta Signed rate delta.
    /// @return next Next reward rate.
    function _addEmissionRate(uint256 rewardRate, int256 delta) private pure returns (uint256 next) {
        unchecked {
            next = uint256(int256(rewardRate) + delta);
        }
        if (next > type(uint192).max) revert MaxRateDeltaPerTime();
    }

    /// @notice Adds a signed change to a scheduled reward-rate delta and checks the bound.
    /// @param rateDelta Current scheduled delta.
    /// @param change Signed change to apply.
    /// @return next Next scheduled delta.
    function _addConstrainRateDelta(int256 rateDelta, int256 change) private pure returns (int256 next) {
        unchecked {
            next = rateDelta + change;
        }

        if (FixedPointMathLib.abs(next) > VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA) {
            revert MaxRateDeltaPerTime();
        }
    }

    /// @notice Updates a global scheduled emission-rate delta at a valid time.
    /// @param time Valid schedule time.
    /// @param delta Signed emission-rate delta to add at `time`.
    function _updateEmissionTime(uint64 time, int256 delta) private {
        int256 rateDelta = _emissionRateDeltaAtTime(time);
        int256 rateDeltaNext = _addConstrainRateDelta(rateDelta, delta);

        _setEmissionRateDeltaAtTime(time, rateDeltaNext);

        if ((rateDelta == 0) != (rateDeltaNext == 0)) {
            _flipEmissionTime(time);
        }
    }

    /// @notice Toggles whether a global emission-rate decrease is scheduled at a valid time.
    /// @param time Valid schedule time.
    function _flipEmissionTime(uint256 time) private {
        (uint256 word, uint8 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            _setEmissionInitializedTimeBitmap(word, _emissionInitializedTimeBitmap(word).toggle(index));
        }
    }

    /// @notice Finds the next initialized global emission schedule time at or after `fromTime`.
    /// @param fromTime Valid time to begin searching from.
    /// @return nextTime Next initialized time in the bitmap word.
    /// @return isInitialized Whether an initialized time was found.
    function _findNextEmissionTime(uint256 fromTime) private view returns (uint256 nextTime, bool isInitialized) {
        unchecked {
            (uint256 word, uint8 index) = timeToBitmapWordAndIndex(fromTime);
            Bitmap bitmap = _emissionInitializedTimeBitmap(word);
            uint256 nextIndex = bitmap.geSetBit(index);

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
}
