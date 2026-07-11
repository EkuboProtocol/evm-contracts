// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {Ve33StorageLayout} from "../libraries/Ve33StorageLayout.sol";
import {ICore, IExtension} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {isPowerOfFour} from "../math/isPowerOfFour.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
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
import {SwapParameters} from "../types/swapParameters.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "../types/feesPerLiquidity.sol";
import {Ve33GlobalEmissionState, createVe33GlobalEmissionState} from "../types/ve33GlobalEmissionState.sol";
import {VePoolSwapFeeState, createVePoolSwapFeeState} from "../types/vePoolSwapFeeState.sol";
import {VePoolVote, createVePoolVote} from "../types/vePoolVote.sol";
import {
    IVe33,
    VE33_CLAIM_POOL_FEES,
    VE33_CLAIM_REWARDS,
    VE33_MAX_STAKE_DURATION,
    VE33_SCHEDULE_EMISSIONS,
    VE33_STAKE,
    VE33_SWAP,
    VE33_UNSTAKE
} from "../interfaces/extensions/IVe33.sol";

// Maximum absolute scheduled emission-rate delta allowed at one valid time.
uint256 constant VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA = type(uint160).max / MAX_NUM_VALID_TIMES;
// Saved-balance salt for all stake-token balances, including staked balances and scheduled emissions.
bytes32 constant VE33_STAKE_TOKEN_SAVED_BALANCE_ID = bytes32(0);
// Saved-balance salt for all voter pool fees, shared by token pair.
bytes32 constant VE33_POOL_FEES_SAVED_BALANCE_ID = bytes32(uint256(1));

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

abstract contract Ve33Storage {
    using ExposedStorageLib for *;

    function _stakeAmount(address owner, StakeId stakeId) internal view returns (uint128 amount) {
        amount = uint128(uint256(Ve33StorageLayout.stakeAmountSlot(owner, stakeId).load()));
    }

    function _setStakeAmount(address owner, StakeId stakeId, uint128 amount) internal {
        Ve33StorageLayout.stakeAmountSlot(owner, stakeId).store(bytes32(uint256(amount)));
    }

    function _votedPoolId(address owner, StakeId stakeId) internal view returns (PoolId poolId) {
        poolId = PoolId.wrap(Ve33StorageLayout.votedPoolIdSlot(owner, stakeId).load());
    }

    function _setVotedPoolId(address owner, StakeId stakeId, PoolId poolId) internal {
        Ve33StorageLayout.votedPoolIdSlot(owner, stakeId).store(PoolId.unwrap(poolId));
    }

    function _vePoolVote(address owner, StakeId stakeId) internal view returns (VePoolVote veVote) {
        veVote = VePoolVote.wrap(Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).load());
    }

    function _setVePoolVote(address owner, StakeId stakeId, VePoolVote veVote) internal {
        Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).store(VePoolVote.unwrap(veVote));
    }

    function _deleteVePoolVote(address owner, StakeId stakeId) internal {
        Ve33StorageLayout.vePoolVoteSlot(owner, stakeId).store(bytes32(0));
    }

    function _vePoolFeeGrowthSnapshot(address owner, StakeId stakeId)
        internal
        view
        returns (FeesPerLiquidity memory feeGrowthSnapshot)
    {
        StorageSlot slot = Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId);
        (bytes32 value0, bytes32 value1) = slot.loadTwo();
        feeGrowthSnapshot.value0 = uint256(value0);
        feeGrowthSnapshot.value1 = uint256(value1);
    }

    function _setVePoolFeeGrowthSnapshot(address owner, StakeId stakeId, FeesPerLiquidity memory feeGrowthSnapshot)
        internal
    {
        Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId)
            .storeTwo(bytes32(feeGrowthSnapshot.value0), bytes32(feeGrowthSnapshot.value1));
    }

    function _deleteVePoolFeeGrowthSnapshot(address owner, StakeId stakeId) internal {
        Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId).storeTwo(bytes32(0), bytes32(0));
    }

    function _positionRewardsSnapshotPerLiquidity(PoolId poolId, address owner, PositionId positionId)
        internal
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
    ) internal {
        Ve33StorageLayout.positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId).store(bytes32(snapshot));
    }

    function _tickRewardsOutsidePerLiquidity(PoolId poolId, int32 tick) internal view returns (uint256) {
        return uint256(Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick).load());
    }

    function _setTickRewardsOutsidePerLiquidity(PoolId poolId, int32 tick, uint256 value) internal {
        Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick).store(bytes32(value));
    }

    function _poolEmissionGrowthGlobalX128Snapshot(PoolId poolId) internal view returns (uint256) {
        return uint256(Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId).load());
    }

    function _setPoolEmissionGrowthGlobalX128Snapshot(PoolId poolId, uint256 value) internal {
        Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId).store(bytes32(value));
    }

    function _poolFeeWeightSum(PoolId poolId) internal view returns (uint192) {
        return uint192(uint256(Ve33StorageLayout.poolFeeWeightSumSlot(poolId).load()));
    }

    function _poolSwapFeeState(PoolId poolId) internal view returns (VePoolSwapFeeState) {
        return VePoolSwapFeeState.wrap(Ve33StorageLayout.poolSwapFeeStateSlot(poolId).load());
    }

    function _setPoolVoteState(PoolId poolId, uint192 feeWeightSum, uint128 totalWeight)
        internal
        returns (uint64 swapFee)
    {
        assembly ("memory-safe") {
            swapFee := div(feeWeightSum, totalWeight)
        }
        Ve33StorageLayout.poolFeeWeightSumSlot(poolId).store(bytes32(uint256(feeWeightSum)));
        Ve33StorageLayout.poolSwapFeeStateSlot(poolId)
            .store(VePoolSwapFeeState.unwrap(createVePoolSwapFeeState(totalWeight, swapFee)));
    }

    function _poolFeeGrowth(PoolId poolId) internal view returns (FeesPerLiquidity memory feeGrowth) {
        StorageSlot slot = Ve33StorageLayout.poolFeeGrowthSlot(poolId);
        (bytes32 value0, bytes32 value1) = slot.loadTwo();
        feeGrowth.value0 = uint256(value0);
        feeGrowth.value1 = uint256(value1);
    }

    function _setPoolFeeGrowth(PoolId poolId, FeesPerLiquidity memory feeGrowth) internal {
        Ve33StorageLayout.poolFeeGrowthSlot(poolId).storeTwo(bytes32(feeGrowth.value0), bytes32(feeGrowth.value1));
    }

    function _rewardsGlobalPerLiquidity(PoolId poolId) internal view returns (uint256) {
        return uint256(Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId).load());
    }

    function _setRewardsGlobalPerLiquidity(PoolId poolId, uint256 value) internal {
        Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId).store(bytes32(value));
    }

    function _emissionRateDeltaAtTime(uint256 time) internal view returns (int256) {
        return int256(uint256(Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time).load()));
    }

    function _setEmissionRateDeltaAtTime(uint256 time, int256 value) internal {
        Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time).store(bytes32(uint256(value)));
    }

    function _emissionInitializedTimeBitmap(uint256 word) internal view returns (Bitmap) {
        return Bitmap.wrap(uint256(Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word).load()));
    }

    function _setEmissionInitializedTimeBitmap(uint256 word, Bitmap bitmap) internal {
        Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word).store(bytes32(Bitmap.unwrap(bitmap)));
    }

    function _totalVoteWeight() internal view returns (uint128) {
        return uint128(uint256(Ve33StorageLayout.totalVoteWeightSlot().load()));
    }

    function _setTotalVoteWeight(uint128 weight) internal {
        Ve33StorageLayout.totalVoteWeightSlot().store(bytes32(uint256(weight)));
    }

    function _emissionGrowthGlobalX128() internal view returns (uint256) {
        return uint256(Ve33StorageLayout.emissionGrowthGlobalX128Slot().load());
    }

    function _setEmissionGrowthGlobalX128(uint256 value) internal {
        Ve33StorageLayout.emissionGrowthGlobalX128Slot().store(bytes32(value));
    }

    function _globalEmissionState() internal view returns (Ve33GlobalEmissionState state) {
        state = Ve33GlobalEmissionState.wrap(Ve33StorageLayout.emissionRateAndLastAccruedSlot().load());
    }

    function _setGlobalEmissionState(Ve33GlobalEmissionState state) internal {
        Ve33StorageLayout.emissionRateAndLastAccruedSlot().store(Ve33GlobalEmissionState.unwrap(state));
    }
}

/// @title Ve33
/// @notice Forward-only ve(3,3) pool extension with dynamic voter fees and single-token LP rewards.
/// @dev Pools using this extension must have zero Core pool fees. Swap fees are accounted by the extension and
/// distributed to ve stakers, while LPs earn the immutable `stakeToken` as rewards.
contract Ve33 is IVe33, BaseExtension, BaseForwardee, ExposedStorage, Ve33Storage {
    using CoreLib for *;
    using ExposedStorageLib for *;

    /// @notice Token used for ve staking, global emissions, and LP rewards.
    address public immutable stakeToken;

    /// @notice Initializes the extension with Core and the immutable reward/stake token.
    /// @param core Ekubo Core contract.
    /// @param _stakeToken Token used for ve stakes and LP rewards.
    constructor(ICore core, address _stakeToken) BaseExtension(core) BaseForwardee(core) {
        stakeToken = _stakeToken;
        _setGlobalEmissionState(createVe33GlobalEmissionState({rate: 0, lastAccruedTime: uint32(block.timestamp)}));
    }

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return ve33CallPoints();
    }

    /// @notice Validates extension-specific pool configuration before Core initializes a new pool.
    /// @dev Pools must use zero Core fee because the active fee is stored in Ve33 pool vote state.
    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension, IExtension) {
        checkValidPoolKey(poolKey);
    }

    /// @notice Initializes extension reward state after Core initializes a new pool.
    function afterInitializePool(address, PoolKey memory poolKey, int32, SqrtRatio)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        _maybeAccumulatePoolRewards({poolId: poolId, liquidity: 0});
    }

    /// @notice Rejects direct Core swaps.
    /// @dev Swaps must be executed through `forward` with `VE33_SWAP` so extension fees can be accounted.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension, IExtension) {
        revert SwapMustHappenThroughForward();
    }

    /// @notice Snapshots LP reward accounting before a position's liquidity changes.
    /// @dev Keeps range-aware reward accounting synchronized with Core position updates.
    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (liquidityDelta == 0) return;

        PoolId poolId = poolKey.toPoolId();
        PoolState coreState = CORE.poolState(poolId);
        _maybeAccumulatePoolRewards(poolId, coreState.liquidity());

        address owner = locker.addr();
        uint128 liquidity = _poolPositionLiquidity(poolId, owner, positionId);
        int32 tick = coreState.tick();
        uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
        uint256 rewardsInsidePerLiquidity = poolKey.config.isStableswap()
            ? _rewardsGlobalPerLiquidity(poolId)
            : _getRewardsInsidePerLiquidity(poolId, tick, positionId.tickLower(), positionId.tickUpper());
        uint256 snapshot = _positionRewardsSnapshotPerLiquidity(poolId, owner, positionId);
        uint256 amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

        if (poolKey.config.isConcentrated()) {
            _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickLower(), liquidityDelta);
            _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickUpper(), liquidityDelta);
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

    /// @inheritdoc IVe33
    function getPoolRewardsPerLiquidityInside(PoolId poolId, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint256)
    {
        return _getRewardsInsidePerLiquidity(poolId, CORE.poolState(poolId).tick(), tickLower, tickUpper);
    }

    /// @notice Computes the current voting power for a stake.
    /// @dev Voting power decays linearly to zero at `stakeId.endTime()`.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Canonical stake id.
    /// @return power Current voting power.
    function _votingPower(address owner, StakeId stakeId) private view returns (uint128 power) {
        return _votingPower(_stakeAmount(owner, stakeId), stakeId);
    }

    function _votingPower(uint128 amount, StakeId stakeId) private view returns (uint128 power) {
        uint64 endTime = stakeId.endTime();
        uint64 secondsUntilEnd = _secondsUntilStakeEnd(endTime);
        if (secondsUntilEnd == 0 || secondsUntilEnd > VE33_MAX_STAKE_DURATION) return 0;

        unchecked {
            power = uint128((uint256(amount) * secondsUntilEnd) / VE33_MAX_STAKE_DURATION);
        }
    }

    /// @notice Returns seconds until a real uint64 stake timestamp.
    function _secondsUntilStakeEnd(uint64 endTime) private view returns (uint64) {
        if (endTime <= block.timestamp) return 0;
        return endTime - uint64(block.timestamp);
    }

    /// @notice Checks that a pool key is configured for Ve33 accounting.
    /// @dev Ve33 pools must use this extension, zero Core fee, and power-of-four concentrated tick spacing.
    function checkValidPoolKey(PoolKey memory poolKey) private view {
        if (poolKey.config.fee() != 0) revert FeeMustBeZero();
        if (poolKey.config.isConcentrated()) {
            uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
            if (!isPowerOfFour(tickSpacing)) revert TickSpacingMustBePowerOfFour();
        }
        if (poolKey.config.extension() != address(this)) revert IncorrectPoolExtension();
    }

    function _poolPositionLiquidity(PoolId poolId, address owner, PositionId positionId)
        private
        view
        returns (uint128 liquidity)
    {
        bytes32 data = CORE.sload(CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId));
        assembly ("memory-safe") {
            liquidity := shr(128, data)
        }
    }

    /// @notice Replaces the vote for a stake owned by the caller.
    /// @dev The stake's full current voting power is assigned to `poolKey`.
    /// @param stakeId Stake whose votes are being updated.
    /// @param poolKey Pool receiving the stake's full active voting power.
    /// @param swapFee Explicit swap fee vote for the pool.
    function vote(StakeId stakeId, PoolKey calldata poolKey, uint64 swapFee) external {
        checkValidPoolKey(poolKey);

        uint128 power = _votingPower(msg.sender, stakeId);
        if (power == 0) {
            _clearVote(msg.sender, stakeId);
            return;
        }

        PoolId poolId = poolKey.toPoolId();
        PoolState coreState = CORE.poolState(poolId);
        if (!coreState.isInitialized()) revert PoolNotInitialized();

        _clearVote(msg.sender, stakeId);

        _maybeAccumulatePoolRewards(poolId, coreState.liquidity());

        uint128 totalWeight = _poolSwapFeeState(poolId).totalWeight();
        uint192 feeWeightSum = _poolFeeWeightSum(poolId);

        unchecked {
            totalWeight += power;
            feeWeightSum += uint192(uint256(power) * swapFee);
            _setTotalVoteWeight(_totalVoteWeight() + power);
        }
        uint64 currentSwapFee = _setPoolVoteState(poolId, feeWeightSum, totalWeight);

        _setVotedPoolId(msg.sender, stakeId, poolId);
        _setVePoolVote(msg.sender, stakeId, createVePoolVote(power, swapFee, uint64(block.timestamp)));
        _setVePoolFeeGrowthSnapshot(msg.sender, stakeId, _poolFeeGrowth(poolId));

        emit VoteWeightApplied(msg.sender, stakeId, poolId, power, currentSwapFee);
    }

    /// @notice Clears the active vote for a stake owned by the caller.
    /// @dev Pending unclaimed voter fees for the stake's current pool are discarded.
    /// @param stakeId Stake whose vote is cleared.
    function clearVote(StakeId stakeId) external {
        _clearVote(msg.sender, stakeId);
    }

    /// @notice Moves stake between two stake keys owned by the caller.
    /// @dev Does not require a Core lock because no token balance changes.
    /// @param fromStakeId Source stake id.
    /// @param toStakeId Destination stake id.
    /// @param amount Amount of stake to move.
    /// @return nextAmount Destination stake amount after the move.
    function moveStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount) external returns (uint128 nextAmount) {
        if (amount == 0) return _stakeAmount(msg.sender, toStakeId);
        if (StakeId.unwrap(fromStakeId) == StakeId.unwrap(toStakeId)) {
            uint128 sameStakeAmount = _stakeAmount(msg.sender, fromStakeId);
            if (amount > sameStakeAmount) revert StakeAmountExceedsBalance();
            return sameStakeAmount;
        }

        if (toStakeId.endTime() < fromStakeId.endTime()) revert MoveStakeToEarlierEndTime();
        _validateNewStake(toStakeId);

        uint128 currentAmount = _stakeAmount(msg.sender, fromStakeId);
        if (amount > currentAmount) revert StakeAmountExceedsBalance();

        PoolId fromPoolId = _votedPoolId(msg.sender, fromStakeId);
        PoolId toPoolId = _votedPoolId(msg.sender, toStakeId);
        uint128 nextFromAmount = currentAmount - amount;
        _setStakeAmount(msg.sender, fromStakeId, nextFromAmount);
        nextAmount = _stakeAmount(msg.sender, toStakeId) + amount;
        _setStakeAmount(msg.sender, toStakeId, nextAmount);
        _adjustVoteWeight(msg.sender, fromStakeId, fromPoolId, _votingPower(nextFromAmount, fromStakeId));
        _adjustVoteWeight(msg.sender, toStakeId, toPoolId, _votingPower(nextAmount, toStakeId));

        emit StakeChanged(msg.sender, fromStakeId, -int256(uint256(amount)));
        emit StakeChanged(msg.sender, toStakeId, int256(uint256(amount)));
    }

    /// @notice Accumulates global emissions into the pool reward-per-liquidity global value.
    /// @dev If the pool has no liquidity, accrued emissions are not assigned to LPs.
    /// @param poolKey Pool whose reward state is being accumulated.
    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        checkValidPoolKey(poolKey);

        PoolId poolId = poolKey.toPoolId();
        PoolState coreState = CORE.poolState(poolId);

        _maybeAccumulatePoolRewards(poolId, coreState.liquidity());
    }

    /// @notice Handles extension forward calls from Core.
    /// @dev The original locker becomes the LP owner or stake owner depending on the call type.
    /// @param original Locker that initiated the Core forward call.
    /// @param data ABI-encoded call type and payload.
    /// @return result ABI-encoded result for the selected forward call.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType;
        assembly ("memory-safe") {
            callType := mload(add(data, 0x20))
        }

        if (callType == VE33_SWAP) {
            (PoolKey memory poolKey, SwapParameters params) = _decodeSwap(data);
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = _swap(poolKey, params);
            assembly ("memory-safe") {
                result := mload(0x40)
                mstore(result, 0x40)
                mstore(add(result, 0x20), balanceUpdate)
                mstore(add(result, 0x40), stateAfter)
                mstore(0x40, add(result, 0x60))
            }
        } else if (callType == VE33_CLAIM_REWARDS) {
            (, PoolKey memory poolKey, PositionId positionId) = abi.decode(data, (uint256, PoolKey, PositionId));
            result = abi.encode(_claimRewards(poolKey, original.addr(), positionId));
        } else if (callType == VE33_STAKE) {
            (, StakeId stakeId, uint128 amount) = abi.decode(data, (uint256, StakeId, uint128));
            result = abi.encode(_stake(original.addr(), stakeId, amount));
        } else if (callType == VE33_UNSTAKE) {
            (, StakeId stakeId) = abi.decode(data, (uint256, StakeId));
            result = abi.encode(_unstake(original.addr(), stakeId));
        } else if (callType == VE33_CLAIM_POOL_FEES) {
            (, StakeId stakeId, PoolKey memory poolKey) = abi.decode(data, (uint256, StakeId, PoolKey));
            (uint128 amount0, uint128 amount1) = _claimPoolFees(original.addr(), stakeId, poolKey);
            result = abi.encode(amount0, amount1);
        } else if (callType == VE33_SCHEDULE_EMISSIONS) {
            (, uint64 startTime, uint64 endTime, uint160 rewardRate) =
                abi.decode(data, (uint256, uint64, uint64, uint160));
            result = abi.encode(_scheduleEmissions(original.addr(), startTime, endTime, rewardRate));
        } else {
            revert();
        }
    }

    /// @notice Decodes the fixed-size forwarded swap payload without copying its pool key.
    /// @dev Preserves the length and canonical address checks performed by `abi.decode`.
    function _decodeSwap(bytes memory data) private pure returns (PoolKey memory poolKey, SwapParameters params) {
        assembly ("memory-safe") {
            if lt(mload(data), 0xa0) { revert(0, 0) }

            poolKey := add(data, 0x40)
            if or(shr(160, mload(poolKey)), shr(160, mload(add(poolKey, 0x20)))) { revert(0, 0) }

            params := mload(add(poolKey, 0x60))
        }
    }

    /// @notice Executes a forward-only swap and accounts voter fees.
    /// @dev Fees are accounted in the unspecified token: output for exact input, input for exact output.
    /// @param poolKey Pool to swap against.
    /// @param params Swap parameters supplied by the router/caller.
    /// @return balanceUpdate Balance deltas including extension fees.
    /// @return stateAfter Pool state after the Core swap.
    function _swap(PoolKey memory poolKey, SwapParameters params)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        unchecked {
            checkValidPoolKey(poolKey);
            PoolId poolId = poolKey.toPoolId();
            PoolState stateBefore = CORE.poolState(poolId);
            _maybeAccumulatePoolRewards(poolId, stateBefore.liquidity());

            VePoolSwapFeeState swapFeeState = _poolSwapFeeState(poolId);
            uint64 swapFee = swapFeeState.swapFee();
            uint128 feeAmount;
            bool feeIsToken1 = !params.isToken1();
            bool exactOut = params.isExactOut();

            (balanceUpdate, stateAfter) = CORE.swap(0, poolKey, params);

            if (swapFee != 0) {
                int128 delta0 = balanceUpdate.delta0();
                int128 delta1 = balanceUpdate.delta1();
                (int128 feeTokenDelta, int128 nonFeeTokenDelta) = feeIsToken1 ? (delta1, delta0) : (delta0, delta1);

                if (feeTokenDelta != 0 && exactOut == (feeTokenDelta > 0)) {
                    int256 signedFeeTokenDelta = int256(feeTokenDelta);
                    uint128 amount = uint128(FixedPointMathLib.abs(signedFeeTokenDelta));
                    if (exactOut) {
                        feeAmount = amountBeforeFee(amount, swapFee) - amount;
                    } else {
                        feeAmount = computeFee(amount, swapFee);
                    }

                    int128 updatedFeeTokenDelta = SafeCastLib.toInt128(signedFeeTokenDelta + int256(uint256(feeAmount)));
                    (delta0, delta1) = feeIsToken1
                        ? (nonFeeTokenDelta, updatedFeeTokenDelta)
                        : (updatedFeeTokenDelta, nonFeeTokenDelta);
                    balanceUpdate = createPoolBalanceUpdate(delta0, delta1);
                }

                if (feeAmount != 0) {
                    (uint128 feeAmount0, uint128 feeAmount1) =
                        feeIsToken1 ? (uint128(0), feeAmount) : (feeAmount, uint128(0));
                    _updatePoolFeeSavedBalances(poolKey, feeAmount0, feeAmount1);

                    uint128 weight = swapFeeState.totalWeight();
                    if (weight != 0) {
                        StorageSlot feeGrowthSlot = Ve33StorageLayout.poolFeeGrowthSlot(poolId);
                        if (feeIsToken1) feeGrowthSlot = feeGrowthSlot.next();
                        feeGrowthSlot.store(
                            bytes32(uint256(feeGrowthSlot.load()) + ((uint256(feeAmount) << 128) / weight))
                        );
                    }

                    emit PoolFeesAccounted(poolId, feeAmount0, feeAmount1);
                }
            }

            if (poolKey.config.isConcentrated()) {
                _updateCrossedTicks(
                    poolId,
                    stateBefore.tick(),
                    stateAfter.tick(),
                    poolKey.config.concentratedTickSpacing(),
                    params.skipAhead()
                );
            }
        }
    }

    /// @notice Adds swap fees to this extension's saved pool balances.
    function _updatePoolFeeSavedBalances(PoolKey memory poolKey, uint128 feeAmount0, uint128 feeAmount1) private {
        ICore core = CORE;
        bytes4 selector = ICore.updateSavedBalances.selector;
        bytes32 savedBalanceId = VE33_POOL_FEES_SAVED_BALANCE_ID;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, selector)
            mstore(add(free, 0x04), mload(poolKey))
            mstore(add(free, 0x24), mload(add(poolKey, 0x20)))
            mstore(add(free, 0x44), savedBalanceId)
            mstore(add(free, 0x64), feeAmount0)
            mstore(add(free, 0x84), feeAmount1)

            if iszero(call(gas(), core, 0, free, 0xa4, 0, 0)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }
        }
    }

    /// @notice Validates that a new or moved-to stake is active.
    /// @param stakeId Proposed stake id.
    function _validateNewStake(StakeId stakeId) private view {
        uint64 endTime = stakeId.endTime();
        uint64 secondsUntilEnd = _secondsUntilStakeEnd(endTime);
        if (secondsUntilEnd == 0) revert StakeEndNotInFuture();
        if (secondsUntilEnd > VE33_MAX_STAKE_DURATION) revert StakeDurationTooLong();
    }

    /// @notice Adds stake and records the saved balance under this extension.
    /// @dev Does not transfer tokens; the calling stake representation settles the payment in the same Core lock.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id.
    /// @param amount Amount of stake to add.
    /// @return nextAmount Stake amount after the increase.
    function _stake(address owner, StakeId stakeId, uint128 amount) private returns (uint128 nextAmount) {
        if (amount == 0) return _stakeAmount(owner, stakeId);

        _validateNewStake(stakeId);

        nextAmount = _stakeAmount(owner, stakeId) + amount;
        _setStakeAmount(owner, stakeId, nextAmount);
        _adjustVoteWeight(owner, stakeId, _votedPoolId(owner, stakeId), _votingPower(nextAmount, stakeId));
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID, int256(uint256(amount)), 0
        );

        emit StakeChanged(owner, stakeId, int256(uint256(amount)));
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
        uint64 secondsUntilEnd = _secondsUntilStakeEnd(endTime);
        if (secondsUntilEnd != 0 && secondsUntilEnd <= VE33_MAX_STAKE_DURATION) revert StakeNotExpired();

        _clearVote(owner, stakeId);
        _setStakeAmount(owner, stakeId, 0);
        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID, -int256(uint256(unstaked)), 0
        );

        emit StakeChanged(owner, stakeId, -int256(uint256(unstaked)));
    }

    /// @notice Claims accrued voter fees while this extension is handling a forwarded call.
    /// @dev Subtracts fees from the extension's saved balance. The forwarding locker withdraws the tokens.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake claiming fees.
    /// @param poolKey Pool whose fees are claimed.
    /// @return amount0 Claimed token0 amount.
    /// @return amount1 Claimed token1 amount.
    function _claimPoolFees(address owner, StakeId stakeId, PoolKey memory poolKey)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        if (PoolId.unwrap(poolId) != PoolId.unwrap(_votedPoolId(owner, stakeId))) revert PoolNotVoted();

        VePoolVote veVote = _vePoolVote(owner, stakeId);

        FeesPerLiquidity memory feeGrowth = _poolFeeGrowth(poolId);
        FeesPerLiquidity memory feeGrowthSnapshot = _vePoolFeeGrowthSnapshot(owner, stakeId);
        (amount0, amount1) = veVote.fees(feeGrowth, feeGrowthSnapshot);

        if (amount0 != 0 || amount1 != 0) {
            _setVePoolFeeGrowthSnapshot(owner, stakeId, feeGrowth);
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                VE33_POOL_FEES_SAVED_BALANCE_ID,
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );

            emit PoolFeesClaimed(poolId, owner, stakeId, amount0, amount1);
        }
    }

    /// @notice Schedules global ve emissions for a chosen valid time range.
    /// @dev Saves the required amount in Core; the forwarding locker must pay `stakeToken` into Core.
    /// @param funder Account recorded in the schedule event.
    /// @param startTime Real emission schedule start time, or zero for immediate start.
    /// @param endTime Emission schedule end time.
    /// @param rewardRate Q32 global emission rate in stake tokens per second.
    /// @return amount Amount of `stakeToken` required by the schedule.
    function _scheduleEmissions(address funder, uint64 startTime, uint64 endTime, uint160 rewardRate)
        private
        returns (uint128 amount)
    {
        if (rewardRate == 0) return 0;

        uint256 realStartTime = FixedPointMathLib.max(block.timestamp, startTime);

        if (
            !isTimeValid({currentTime: block.timestamp, time: startTime})
                || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= realStartTime
        ) {
            revert InvalidTimestamps();
        }

        unchecked {
            // realDuration is less than 2**32 because startTime and endTime are valid and endTime is in the future.
            // The rounded Q32 amount fits the uint128 saved-balance path for any fundable schedule.
            uint256 realDuration = endTime - realStartTime;
            uint256 requiredAmount = ((realDuration * rewardRate) + type(uint32).max) >> 32;
            if (requiredAmount > type(uint128).max) revert EmissionFundingOverflow();
            amount = uint128(requiredAmount);
        }

        accrueEmissions();

        CORE.updateSavedBalances(
            stakeToken, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID, int256(uint256(amount)), 0
        );

        int256 rewardRateDelta = int256(uint256(rewardRate));
        if (startTime > block.timestamp) {
            _updateEmissionTime(startTime, rewardRateDelta);
        } else {
            (uint160 rate, uint32 lastAccrued) = _globalEmissionState().parse();
            unchecked {
                rate += rewardRate;
            }
            _setGlobalEmissionState(createVe33GlobalEmissionState(rate, lastAccrued));
        }

        _updateEmissionTime(endTime, -rewardRateDelta);

        emit EmissionsScheduled(funder, startTime, endTime, rewardRate, amount);
    }

    /// @notice Claims reward tokens earned by an LP position.
    /// @dev Uses range-aware reward growth and then resets the position snapshot.
    /// @param poolKey Pool containing the position.
    /// @param owner Position owner.
    /// @param positionId Position claiming rewards.
    /// @return amount Claimed reward amount.
    function _claimRewards(PoolKey memory poolKey, address owner, PositionId positionId)
        private
        returns (uint256 amount)
    {
        checkValidPoolKey(poolKey);
        PoolId poolId = poolKey.toPoolId();
        PoolState coreState = CORE.poolState(poolId);
        _maybeAccumulatePoolRewards(poolId, coreState.liquidity());

        uint128 liquidity = _poolPositionLiquidity(poolId, owner, positionId);
        uint256 snapshot = _positionRewardsSnapshotPerLiquidity(poolId, owner, positionId);

        uint256 rewardsInsidePerLiquidity = poolKey.config.isStableswap()
            ? _rewardsGlobalPerLiquidity(poolId)
            : _getRewardsInsidePerLiquidity(poolId, coreState.tick(), positionId.tickLower(), positionId.tickUpper());
        amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

        _setPositionRewardsSnapshotPerLiquidity(
            poolId, owner, positionId, liquidity == 0 ? 0 : rewardsInsidePerLiquidity
        );

        if (amount != 0) {
            uint128 amountUint128 = uint128(amount);
            CORE.updateSavedBalances(
                stakeToken,
                address(type(uint160).max),
                VE33_STAKE_TOKEN_SAVED_BALANCE_ID,
                -int256(uint256(amountUint128)),
                0
            );

            emit RewardsClaimed(poolId, owner, positionId, amount);
        }
    }

    /// @notice Clears the active vote for a stake.
    /// @dev Pending voter fees are discarded when a vote is fully cleared, matching zero-liquidity Core positions.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose votes are cleared.
    function _clearVote(address owner, StakeId stakeId) private {
        _adjustVoteWeight(owner, stakeId, _votedPoolId(owner, stakeId), 0);
    }

    /// @notice Adjusts a stake's active vote weight for one pool.
    /// @dev Accrues reward and voter-fee accounting before changing future weights. If `nextWeight` is zero, the vote
    ///      is fully cleared and pending voter fees are discarded.
    /// @param owner Locker representation that owns the stake.
    /// @param stakeId Stake id whose vote is adjusted.
    /// @param poolId Pool whose vote totals contain the stake.
    /// @param nextWeight New vote weight for the stake.
    function _adjustVoteWeight(address owner, StakeId stakeId, PoolId poolId, uint128 nextWeight) private {
        VePoolVote veVote = _vePoolVote(owner, stakeId);
        uint128 previousWeight = veVote.weight();
        if (previousWeight == nextWeight) return;
        if (previousWeight == 0) return;

        _maybeAccumulatePoolRewards(poolId, CORE.poolState(poolId).liquidity());

        uint128 totalWeight = _poolSwapFeeState(poolId).totalWeight();
        uint192 feeWeightSum = _poolFeeWeightSum(poolId);
        FeesPerLiquidity memory feeGrowthSnapshot;
        (veVote, feeGrowthSnapshot) = _setVePoolVoteWeight(
            _poolFeeGrowth(poolId),
            _vePoolFeeGrowthSnapshot(owner, stakeId),
            veVote,
            nextWeight,
            uint64(block.timestamp)
        );
        unchecked {
            totalWeight = totalWeight - previousWeight + nextWeight;
            feeWeightSum = feeWeightSum - uint192(uint256(previousWeight) * veVote.swapFee())
                + uint192(uint256(nextWeight) * veVote.swapFee());
            _setTotalVoteWeight(_totalVoteWeight() - previousWeight + nextWeight);
        }
        uint64 currentSwapFee = _setPoolVoteState(poolId, feeWeightSum, totalWeight);

        if (nextWeight == 0) {
            _setVotedPoolId(owner, stakeId, PoolId.wrap(bytes32(0)));
            _deleteVePoolVote(owner, stakeId);
            _deleteVePoolFeeGrowthSnapshot(owner, stakeId);
            emit VoteWeightApplied(owner, stakeId, poolId, 0, currentSwapFee);
        } else {
            _setVePoolVote(owner, stakeId, veVote);
            _setVePoolFeeGrowthSnapshot(owner, stakeId, feeGrowthSnapshot);
            emit VoteWeightApplied(owner, stakeId, poolId, nextWeight, currentSwapFee);
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

    /// @notice Accumulates global emissions into one pool's LP reward growth if its emission snapshot changed.
    /// @param poolId Pool whose reward state is being accumulated.
    /// @param liquidity Current Core pool liquidity.
    function _maybeAccumulatePoolRewards(PoolId poolId, uint128 liquidity) private {
        unchecked {
            accrueEmissions();

            uint256 emissionGrowthGlobalX128_ = _emissionGrowthGlobalX128();
            uint256 snapshot = _poolEmissionGrowthGlobalX128Snapshot(poolId);
            if (snapshot != emissionGrowthGlobalX128_) {
                _setPoolEmissionGrowthGlobalX128Snapshot(poolId, emissionGrowthGlobalX128_);

                uint128 weight = _poolSwapFeeState(poolId).totalWeight();
                if (weight != 0) {
                    uint256 emissionRewardsAccrued =
                        FixedPointMathLib.fullMulDivN(emissionGrowthGlobalX128_ - snapshot, weight, 128);

                    if (emissionRewardsAccrued != 0) {
                        if (liquidity != 0) {
                            _setRewardsGlobalPerLiquidity(
                                poolId,
                                _rewardsGlobalPerLiquidity(poolId) + ((emissionRewardsAccrued << 128) / liquidity)
                            );
                        }

                        emit PoolEmissionsAccrued(poolId, emissionRewardsAccrued);
                    }
                }
            }
        }
    }

    /// @notice Accrues global emissions into global emission growth.
    function accrueEmissions() public {
        Ve33GlobalEmissionState globalEmissionState = _globalEmissionState();
        uint160 rate = globalEmissionState.emissionRate();
        uint256 lastAccruedTime = globalEmissionState.realEmissionTimeAtOrBeforeNow();
        if (lastAccruedTime == block.timestamp) return;

        uint256 time = lastAccruedTime;
        uint256 emissionGrowthGlobalX128_ = _emissionGrowthGlobalX128();

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) = _searchForNextEmissionTime(lastAccruedTime, time, block.timestamp);

            uint128 weight = _totalVoteWeight();
            uint256 amount = (uint256(rate) * (eventTime - time)) >> 32;
            assembly ("memory-safe") {
                emissionGrowthGlobalX128_ := add(emissionGrowthGlobalX128_, div(shl(128, amount), weight))
            }
            if (initialized) {
                unchecked {
                    rate = uint160(uint256(int256(uint256(rate)) + _emissionRateDeltaAtTime(eventTime)));
                }
                _setEmissionRateDeltaAtTime(eventTime, 0);
                _flipEmissionTime(eventTime);
            }
            time = eventTime;
        }

        _setEmissionGrowthGlobalX128(emissionGrowthGlobalX128_);
        _setGlobalEmissionState(createVe33GlobalEmissionState(rate, uint32(block.timestamp)));
    }

    /// @notice Updates tick reward snapshots for ticks crossed by a forwarded swap.
    /// @dev Mirrors Core fee-outside inversion so reward growth remains range-aware.
    /// @param poolId Id of `poolKey`.
    /// @param tickBefore Tick before the swap.
    /// @param tickAfter Tick after the swap.
    /// @param tickSpacing Concentrated tick spacing for the pool.
    /// @param skipAhead Tick-bitmap skip-ahead hint supplied to the swap.
    function _updateCrossedTicks(
        PoolId poolId,
        int32 tickBefore,
        int32 tickAfter,
        uint32 tickSpacing,
        uint256 skipAhead
    ) private {
        if (tickBefore == tickAfter) return;

        uint256 rewardsGlobalPerLiquidity_;
        bool rewardsGlobalPerLiquidityLoaded;

        int32 tick = tickBefore;
        if (tickAfter < tickBefore) {
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.prevInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (tick <= tickAfter) break;
                unchecked {
                    if (initialized) {
                        if (!rewardsGlobalPerLiquidityLoaded) {
                            rewardsGlobalPerLiquidity_ = _rewardsGlobalPerLiquidity(poolId);
                            rewardsGlobalPerLiquidityLoaded = true;
                        }
                        _setTickRewardsOutsidePerLiquidity(
                            poolId, tick, rewardsGlobalPerLiquidity_ - _tickRewardsOutsidePerLiquidity(poolId, tick)
                        );
                    }
                    if (tick == MIN_TICK) break;
                    tick--;
                }
            }
        } else {
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.nextInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (tick > tickAfter) break;
                unchecked {
                    if (initialized) {
                        if (!rewardsGlobalPerLiquidityLoaded) {
                            rewardsGlobalPerLiquidity_ = _rewardsGlobalPerLiquidity(poolId);
                            rewardsGlobalPerLiquidityLoaded = true;
                        }
                        _setTickRewardsOutsidePerLiquidity(
                            poolId, tick, rewardsGlobalPerLiquidity_ - _tickRewardsOutsidePerLiquidity(poolId, tick)
                        );
                    }
                    if (tick == MAX_TICK) break;
                }
            }
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
    /// @param tick Position boundary tick.
    /// @param liquidityDelta Position liquidity delta.
    function _updateTickRewardsPerLiquidityOutside(PoolId poolId, int32 tick, int128 liquidityDelta) private {
        (, uint128 liquidityNet) = CORE.poolTicks(poolId, tick);
        uint128 liquidityNetNext = addLiquidityDelta(liquidityNet, liquidityDelta);
        if ((liquidityNet == 0) != (liquidityNetNext == 0)) {
            // Initialize the slot to a non-zero sentinel so the first swap crossing this tick is cheaper.
            // Only changes in the outside snapshot are relevant to position reward accounting.
            uint256 value;
            assembly ("memory-safe") {
                value := iszero(liquidityNet)
            }
            _setTickRewardsOutsidePerLiquidity(poolId, tick, value);
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
    /// @param time Valid real schedule time.
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
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            _setEmissionInitializedTimeBitmap(word, _emissionInitializedTimeBitmap(word).toggle(uint8(index)));
        }
    }

    /// @notice Finds the next initialized global emission schedule time at or after `fromTime`.
    /// @param fromTime Valid time to begin searching from.
    /// @return nextTime Next initialized time in the bitmap word.
    /// @return isInitialized Whether an initialized time was found.
    function _findNextEmissionTime(uint256 fromTime) private view returns (uint256 nextTime, bool isInitialized) {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            Bitmap bitmap = _emissionInitializedTimeBitmap(word);
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

    /// @notice Finds the next initialized global emission schedule time strictly after `fromTime`.
    /// @param fromTime Time after which to search.
    /// @return time Next initialized schedule time, or 0 if none found within the maximum valid range.
    /// @return delta Scheduled emission-rate delta at `time`, or 0 if none found.
    function nextEmissionRateChangeTime(uint256 fromTime) external view returns (uint64 time, int256 delta) {
        uint256 lastAccruedTime = _globalEmissionState().realEmissionTimeAtOrBeforeNow();
        uint256 untilTime;
        unchecked {
            untilTime = block.timestamp + type(uint32).max;
        }
        (uint256 nextTime, bool isInitialized) = _searchForNextEmissionTime(lastAccruedTime, fromTime, untilTime);
        if (isInitialized) {
            time = uint64(nextTime);
            delta = _emissionRateDeltaAtTime(nextTime);
        }
    }
}
