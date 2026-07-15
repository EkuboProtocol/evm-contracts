// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {
    IVe33,
    VE33_CLAIM_POOL_FEES,
    VE33_CLAIM_REWARDS,
    VE33_MAX_STAKE_DURATION,
    VE33_SCHEDULE_EMISSIONS,
    VE33_STAKE,
    VE33_UNSTAKE
} from "../interfaces/extensions/IVe33.sol";
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
import {Ve33GlobalEmissionState} from "../types/ve33GlobalEmissionState.sol";
import {VePoolSwapFeeState} from "../types/vePoolSwapFeeState.sol";
import {VePoolVote} from "../types/vePoolVote.sol";
import {CoreStorageLayout} from "./CoreStorageLayout.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {Ve33StorageLayout} from "./Ve33StorageLayout.sol";

/// @title Ve33 Library
/// @notice Exposed-storage readers for Ve33 state.
/// @dev Storage readers must use Ve33StorageLayout so they match Ve33's manual storage slots.
library Ve33Lib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    /// @notice Executes a Ve33 forwarded swap through Core.
    function swap(ICore core, IVe33 ve33, PoolKey memory poolKey, SwapParameters params)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        bytes memory data = new bytes(128);
        assembly ("memory-safe") {
            let ptr := add(data, 0x20)
            mstore(ptr, mload(poolKey))
            mstore(add(ptr, 0x20), mload(add(poolKey, 0x20)))
            mstore(add(ptr, 0x40), mload(add(poolKey, 0x40)))
            mstore(add(ptr, 0x60), params)
        }

        bytes memory result = core.forward(address(ve33), data);
        assembly ("memory-safe") {
            balanceUpdate := mload(add(result, 0x20))
            stateAfter := mload(add(result, 0x40))
        }
    }

    /// @notice Claims LP rewards for a Ve33 position through Core.
    function claimRewards(ICore core, IVe33 ve33, PoolKey memory poolKey, PositionId positionId)
        internal
        returns (uint256 amount)
    {
        amount = abi.decode(core.forward(address(ve33), abi.encode(VE33_CLAIM_REWARDS, poolKey, positionId)), (uint256));
    }

    /// @notice Stakes tokens into Ve33 through Core.
    function stake(ICore core, IVe33 ve33, StakeId stakeId, uint128 amount) internal returns (uint128 nextAmount) {
        nextAmount = abi.decode(core.forward(address(ve33), abi.encode(VE33_STAKE, stakeId, amount)), (uint128));
    }

    /// @notice Unstakes tokens from Ve33 through Core.
    function unstake(ICore core, IVe33 ve33, StakeId stakeId) internal returns (uint128 unstaked) {
        unstaked = abi.decode(core.forward(address(ve33), abi.encode(VE33_UNSTAKE, stakeId)), (uint128));
    }

    /// @notice Claims pool fees for a Ve33 stake through Core.
    function claimPoolFees(ICore core, IVe33 ve33, StakeId stakeId, PoolKey memory poolKey)
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            core.forward(address(ve33), abi.encode(VE33_CLAIM_POOL_FEES, stakeId, poolKey)), (uint128, uint128)
        );
    }

    /// @notice Schedules global Ve33 emissions through Core.
    function scheduleEmissions(ICore core, IVe33 ve33, uint64 startTime, uint64 endTime, uint160 rewardRate)
        internal
        returns (uint128 amount)
    {
        amount = abi.decode(
            core.forward(address(ve33), abi.encode(VE33_SCHEDULE_EMISSIONS, startTime, endTime, rewardRate)), (uint128)
        );
    }

    /// @notice Returns stake for `(owner, stakeId)`.
    function stakeAmount(IVe33 ve33, address owner, StakeId stakeId) internal view returns (uint128) {
        return uint128(uint256(ve33.sload(Ve33StorageLayout.stakeAmountSlot(owner, stakeId))));
    }

    /// @notice Returns current linearly decaying voting power for a canonical stake key.
    function votingPower(IVe33 ve33, address owner, StakeId stakeId) internal view returns (uint128 power) {
        uint64 endTime = stakeId.endTime();
        uint64 secondsUntilEnd;
        unchecked {
            secondsUntilEnd = endTime - uint64(block.timestamp);
        }
        if (secondsUntilEnd == 0 || secondsUntilEnd > VE33_MAX_STAKE_DURATION) return 0;

        unchecked {
            power = uint128((uint256(stakeAmount(ve33, owner, stakeId)) * secondsUntilEnd) / VE33_MAX_STAKE_DURATION);
        }
    }

    /// @notice Returns the pool currently voted on by `stakeId`.
    function votedPool(IVe33 ve33, address owner, StakeId stakeId) internal view returns (PoolId) {
        return PoolId.wrap(ve33.sload(Ve33StorageLayout.votedPoolIdSlot(owner, stakeId)));
    }

    /// @notice Returns per-stake vote and fee accounting for the currently voted pool.
    function vePoolVote(IVe33 ve33, address owner, StakeId stakeId) internal view returns (VePoolVote vote) {
        vote = VePoolVote.wrap(ve33.sload(Ve33StorageLayout.vePoolVoteSlot(owner, stakeId)));
    }

    /// @notice Returns a stake's snapshot of pool fee growth for its currently voted pool.
    function vePoolFeeGrowthSnapshot(IVe33 ve33, address owner, StakeId stakeId)
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
    function poolEmissionGrowthGlobalX128Snapshot(IVe33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.poolEmissionGrowthGlobalX128SnapshotSlot(poolId)));
    }

    /// @notice Returns a pool's weighted sum of active fee votes.
    function poolFeeWeightSum(IVe33 ve33, PoolId poolId) internal view returns (uint192) {
        return uint192(uint256(ve33.sload(Ve33StorageLayout.poolFeeWeightSumSlot(poolId))));
    }

    /// @notice Returns a pool's packed total active vote weight and current swap fee.
    function poolSwapFeeState(IVe33 ve33, PoolId poolId) internal view returns (VePoolSwapFeeState) {
        return VePoolSwapFeeState.wrap(ve33.sload(Ve33StorageLayout.poolSwapFeeStateSlot(poolId)));
    }

    /// @notice Returns a pool's total active vote weight.
    function poolTotalWeight(IVe33 ve33, PoolId poolId) internal view returns (uint128) {
        return poolSwapFeeState(ve33, poolId).totalWeight();
    }

    /// @notice Returns accumulated pool fees per unit of vote weight.
    function poolFeeGrowth(IVe33 ve33, PoolId poolId) internal view returns (FeesPerLiquidity memory feeGrowth) {
        StorageSlot slot = Ve33StorageLayout.poolFeeGrowthSlot(poolId);
        (bytes32 value0, bytes32 value1) = ve33.sload(slot, slot.next());
        feeGrowth.value0 = uint256(value0);
        feeGrowth.value1 = uint256(value1);
    }

    /// @notice Returns global reward growth per unit of liquidity for a pool.
    function rewardsGlobalPerLiquidity(IVe33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId)));
    }

    /// @notice Returns reward growth outside an initialized tick.
    function tickRewardsOutsidePerLiquidity(IVe33 ve33, PoolId poolId, int32 tick) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.tickRewardsOutsidePerLiquiditySlot(poolId, tick)));
    }

    /// @notice Returns a position reward growth snapshot.
    function positionRewardsSnapshotPerLiquidity(IVe33 ve33, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint256)
    {
        return uint256(ve33.sload(Ve33StorageLayout.positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId)));
    }

    /// @notice Returns a Core position's liquidity without loading extra data or fee-growth snapshots.
    function positionLiquidity(ICore core, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 data = core.sload(CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId));
        assembly ("memory-safe") {
            liquidity := shr(128, data)
        }
    }

    /// @notice Returns total active ve vote weight across all pools.
    function totalVoteWeight(IVe33 ve33) internal view returns (uint256) {
        return uint128(uint256(ve33.sload(Ve33StorageLayout.totalVoteWeightSlot())));
    }

    /// @notice Returns accumulated global emission growth per unit of active vote weight.
    function emissionGrowthGlobalX128(IVe33 ve33) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.emissionGrowthGlobalX128Slot()));
    }

    /// @notice Returns the packed global emission rate and last-accrued timestamp.
    function globalEmissionState(IVe33 ve33) internal view returns (Ve33GlobalEmissionState) {
        return Ve33GlobalEmissionState.wrap(ve33.sload(Ve33StorageLayout.emissionRateAndLastAccruedSlot()));
    }

    /// @notice Returns the current global Q32 emission rate.
    function emissionRate(IVe33 ve33) internal view returns (uint160) {
        return globalEmissionState(ve33).emissionRate();
    }

    /// @notice Returns the last timestamp when global emissions were accrued.
    function emissionsLastAccrued(IVe33 ve33) internal view returns (uint32) {
        return globalEmissionState(ve33).lastAccrued();
    }

    /// @notice Returns one global emission initialized-time bitmap word.
    function emissionInitializedTimeBitmap(IVe33 ve33, uint256 word) internal view returns (uint256) {
        return uint256(ve33.sload(Ve33StorageLayout.emissionInitializedTimeBitmapSlot(word)));
    }

    /// @notice Returns the scheduled global emission-rate delta at `time`.
    function emissionRateDeltaAtTime(IVe33 ve33, uint256 time) internal view returns (int256) {
        return int256(uint256(ve33.sload(Ve33StorageLayout.emissionRateDeltaAtTimeSlot(time))));
    }
}
