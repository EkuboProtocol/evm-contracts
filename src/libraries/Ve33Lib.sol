// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {
    Ve33,
    VE33_CLAIM_POOL_FEES,
    VE33_CLAIM_REWARDS,
    VE33_MAX_STAKE_DURATION,
    VE33_MOVE_STAKE,
    VE33_SCHEDULE_EMISSIONS,
    VE33_SPLIT_STAKE,
    VE33_STAKE,
    VE33_SWAP,
    VE33_UNSTAKE
} from "../extensions/Ve33.sol";
import {ICore} from "../interfaces/ICore.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {StakeId} from "../types/stakeId.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {VePoolFeeState} from "../types/vePoolFeeState.sol";
import {VePoolVote} from "../types/vePoolVote.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {Ve33StorageLayout} from "./Ve33StorageLayout.sol";

/// @title Ve33 Library
/// @notice Exposed-storage readers for Ve33 state.
/// @dev Storage readers must use Ve33StorageLayout so they match Ve33's manual storage slots.
library Ve33Lib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    /// @notice Encodes a Ve33 forwarded swap call.
    function encodeSwap(PoolKey memory poolKey, SwapParameters params) internal pure returns (bytes memory) {
        return abi.encode(VE33_SWAP, poolKey, params);
    }

    /// @notice Decodes a Ve33 forwarded swap result.
    function decodeSwapResult(bytes memory data)
        internal
        pure
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(data, (PoolBalanceUpdate, PoolState));
    }

    /// @notice Executes a Ve33 forwarded swap through Core.
    function swap(ICore core, Ve33 ve33, PoolKey memory poolKey, SwapParameters params)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = decodeSwapResult(core.forward(address(ve33), encodeSwap(poolKey, params)));
    }

    /// @notice Encodes a Ve33 LP reward claim call.
    function encodeClaimRewards(PoolKey memory poolKey, PositionId positionId, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VE33_CLAIM_REWARDS, poolKey, positionId, recipient);
    }

    /// @notice Decodes a Ve33 LP reward claim result.
    function decodeClaimRewardsResult(bytes memory data) internal pure returns (uint256 amount) {
        amount = abi.decode(data, (uint256));
    }

    /// @notice Claims LP rewards for a Ve33 position through Core.
    function claimRewards(ICore core, Ve33 ve33, PoolKey memory poolKey, PositionId positionId, address recipient)
        internal
        returns (uint256 amount)
    {
        amount =
            decodeClaimRewardsResult(core.forward(address(ve33), encodeClaimRewards(poolKey, positionId, recipient)));
    }

    /// @notice Encodes a Ve33 stake call.
    function encodeStake(StakeId stakeId, uint128 amount) internal pure returns (bytes memory) {
        return abi.encode(VE33_STAKE, stakeId, amount);
    }

    /// @notice Decodes a Ve33 stake result.
    function decodeStakeResult(bytes memory data) internal pure returns (uint128 nextAmount) {
        nextAmount = abi.decode(data, (uint128));
    }

    /// @notice Stakes tokens into Ve33 through Core.
    function stake(ICore core, Ve33 ve33, StakeId stakeId, uint128 amount) internal returns (uint128 nextAmount) {
        nextAmount = decodeStakeResult(core.forward(address(ve33), encodeStake(stakeId, amount)));
    }

    /// @notice Encodes a Ve33 unstake call.
    function encodeUnstake(StakeId stakeId) internal pure returns (bytes memory) {
        return abi.encode(VE33_UNSTAKE, stakeId);
    }

    /// @notice Decodes a Ve33 unstake result.
    function decodeUnstakeResult(bytes memory data) internal pure returns (uint128 unstaked) {
        unstaked = abi.decode(data, (uint128));
    }

    /// @notice Unstakes tokens from Ve33 through Core.
    function unstake(ICore core, Ve33 ve33, StakeId stakeId) internal returns (uint128 unstaked) {
        unstaked = decodeUnstakeResult(core.forward(address(ve33), encodeUnstake(stakeId)));
    }

    /// @notice Encodes a Ve33 move-stake call.
    function encodeMoveStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VE33_MOVE_STAKE, fromStakeId, toStakeId, amount);
    }

    /// @notice Decodes a Ve33 move-stake result.
    function decodeMoveStakeResult(bytes memory data) internal pure returns (uint128 nextAmount) {
        nextAmount = abi.decode(data, (uint128));
    }

    /// @notice Moves stake between two Ve33 stake keys through Core.
    function moveStake(ICore core, Ve33 ve33, StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        internal
        returns (uint128 nextAmount)
    {
        nextAmount = decodeMoveStakeResult(core.forward(address(ve33), encodeMoveStake(fromStakeId, toStakeId, amount)));
    }

    /// @notice Encodes a Ve33 split-stake call.
    function encodeSplitStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VE33_SPLIT_STAKE, fromStakeId, toStakeId, amount);
    }

    /// @notice Decodes a Ve33 split-stake result.
    function decodeSplitStakeResult(bytes memory data) internal pure returns (uint128 nextAmount) {
        nextAmount = abi.decode(data, (uint128));
    }

    /// @notice Splits stake between two Ve33 stake keys through Core.
    function splitStake(ICore core, Ve33 ve33, StakeId fromStakeId, StakeId toStakeId, uint128 amount)
        internal
        returns (uint128 nextAmount)
    {
        nextAmount = decodeSplitStakeResult(
            core.forward(address(ve33), encodeSplitStake(fromStakeId, toStakeId, amount))
        );
    }

    /// @notice Encodes a Ve33 pool-fee claim call.
    function encodeClaimPoolFees(StakeId stakeId, PoolKey memory poolKey) internal pure returns (bytes memory) {
        return abi.encode(VE33_CLAIM_POOL_FEES, stakeId, poolKey);
    }

    /// @notice Decodes a Ve33 pool-fee claim result.
    function decodeClaimPoolFeesResult(bytes memory data) internal pure returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(data, (uint128, uint128));
    }

    /// @notice Claims pool fees for a Ve33 stake through Core.
    function claimPoolFees(ICore core, Ve33 ve33, StakeId stakeId, PoolKey memory poolKey)
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) =
            decodeClaimPoolFeesResult(core.forward(address(ve33), encodeClaimPoolFees(stakeId, poolKey)));
    }

    /// @notice Encodes a Ve33 global-emission schedule call.
    function encodeScheduleEmissions(uint64 startTime, uint64 endTime, uint224 rewardRate)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VE33_SCHEDULE_EMISSIONS, startTime, endTime, rewardRate);
    }

    /// @notice Decodes a Ve33 global-emission schedule result.
    function decodeScheduleEmissionsResult(bytes memory data) internal pure returns (uint224 amount) {
        amount = abi.decode(data, (uint224));
    }

    /// @notice Schedules global Ve33 emissions through Core.
    function scheduleEmissions(ICore core, Ve33 ve33, uint64 startTime, uint64 endTime, uint224 rewardRate)
        internal
        returns (uint224 amount)
    {
        amount = decodeScheduleEmissionsResult(
            core.forward(address(ve33), encodeScheduleEmissions(startTime, endTime, rewardRate))
        );
    }

    /// @notice Returns stake for `(owner, stakeId)`.
    function stakeAmount(Ve33 ve33, address owner, StakeId stakeId) internal view returns (uint128) {
        return uint128(uint256(ve33.sload(Ve33StorageLayout.stakeAmountSlot(owner, stakeId))));
    }

    /// @notice Returns current linearly decaying voting power for a canonical stake key.
    function votingPower(Ve33 ve33, address owner, StakeId stakeId) internal view returns (uint128 power) {
        uint64 endTime = stakeId.endTime();
        if (block.timestamp >= endTime) return 0;

        unchecked {
            power = uint128(
                (uint256(stakeAmount(ve33, owner, stakeId)) * (endTime - block.timestamp)) / VE33_MAX_STAKE_DURATION
            );
        }
    }

    /// @notice Returns the pool currently voted on by `stakeId`.
    function votedPool(Ve33 ve33, address owner, StakeId stakeId) internal view returns (PoolId) {
        return PoolId.wrap(ve33.sload(Ve33StorageLayout.votedPoolIdSlot(owner, stakeId)));
    }

    /// @notice Returns per-stake vote and fee accounting for the currently voted pool.
    function vePoolVote(Ve33 ve33, address owner, StakeId stakeId) internal view returns (VePoolVote vote) {
        vote = VePoolVote.wrap(ve33.sload(Ve33StorageLayout.vePoolVoteSlot(owner, stakeId)));
    }

    /// @notice Returns a stake's snapshot of pool fee growth for its currently voted pool.
    function vePoolFeeGrowthSnapshot(Ve33 ve33, address owner, StakeId stakeId)
        internal
        view
        returns (FeesPerLiquidity memory feeGrowthSnapshot)
    {
        StorageSlot slot = Ve33StorageLayout.vePoolFeeGrowthSnapshotSlot(owner, stakeId);
        (bytes32 value0, bytes32 value1) = ve33.sload(slot, slot.next());
        feeGrowthSnapshot.value0 = uint256(value0);
        feeGrowthSnapshot.value1 = uint256(value1);
    }

    /// @notice Returns a pool's emission-growth snapshot.
    function poolEmissionGrowthGlobalX128Snapshot(Ve33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId)));
    }

    /// @notice Returns a pool's packed fee-weight sum and cached swap fee.
    function poolFeeState(Ve33 ve33, PoolId poolId) internal view returns (VePoolFeeState) {
        return VePoolFeeState.wrap(ve33.sload(Ve33StorageLayout.poolFeeStateSlot(poolId)));
    }

    /// @notice Returns a pool's total active vote weight.
    function poolTotalWeight(Ve33 ve33, PoolId poolId) internal view returns (uint128) {
        return uint128(uint256(ve33.sload(Ve33StorageLayout.poolTotalWeightSlot(poolId))));
    }

    /// @notice Returns accumulated pool fees per unit of vote weight.
    function poolFeeGrowth(Ve33 ve33, PoolId poolId) internal view returns (FeesPerLiquidity memory feeGrowth) {
        StorageSlot slot = Ve33StorageLayout.poolFeeGrowthSlot(poolId);
        (bytes32 value0, bytes32 value1) = ve33.sload(slot, slot.next());
        feeGrowth.value0 = uint256(value0);
        feeGrowth.value1 = uint256(value1);
    }

    /// @notice Returns global reward growth per unit of liquidity for a pool.
    function rewardsGlobalPerLiquidity(Ve33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId)));
    }

    /// @notice Returns reward growth outside an initialized tick.
    function tickRewardsOutsidePerLiquidity(Ve33 ve33, PoolId poolId, int32 tick) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick)));
    }

    /// @notice Returns a position reward growth snapshot.
    function positionRewardsSnapshotPerLiquidity(Ve33 ve33, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint256)
    {
        return uint256(ve33.sload(Ve33StorageLayout.positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId)));
    }

    /// @notice Returns total active ve vote weight across all pools.
    function totalVoteWeight(Ve33 ve33) internal view returns (uint256) {
        return uint128(uint256(ve33.sload(Ve33StorageLayout.totalVoteWeightSlot())));
    }

    /// @notice Returns accumulated global emission growth per unit of active vote weight.
    function emissionGrowthGlobalX128(Ve33 ve33) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.emissionGrowthGlobalX128Slot()));
    }

    /// @notice Returns the current global Q32 emission rate.
    function emissionRate(Ve33 ve33) internal view returns (uint192) {
        return uint192(uint256(ve33.sload(Ve33StorageLayout.emissionRateAndLastAccruedSlot())));
    }

    /// @notice Returns the last timestamp when global emissions were accrued.
    function emissionsLastAccrued(Ve33 ve33) internal view returns (uint64) {
        return uint64(uint256(ve33.sload(Ve33StorageLayout.emissionRateAndLastAccruedSlot())) >> 192);
    }

    /// @notice Returns one global emission initialized-time bitmap word.
    function emissionInitializedTimeBitmap(Ve33 ve33, uint256 word) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word)));
    }

    /// @notice Returns the scheduled global emission-rate delta at `time`.
    function emissionRateDeltaAtTime(Ve33 ve33, uint64 time) internal view returns (int256) {
        return int256(uint256(ve33.sload(Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time))));
    }
}
