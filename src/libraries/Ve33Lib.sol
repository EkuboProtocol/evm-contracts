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
import {PoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {StakeId} from "../types/stakeId.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

/// @title Ve33 Library
/// @notice Exposed-storage readers for Ve33 state.
/// @dev Slot constants match Ve33's declared storage layout. Ve33 inherits only storage-less bases.
library Ve33Lib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    uint256 private constant STAKE_AMOUNTS_SLOT = 0;
    uint256 private constant VOTED_POOL_IDS_SLOT = 1;
    uint256 private constant VE_POOL_POSITIONS_SLOT = 2;
    uint256 private constant POOL_VOTE_STATES_SLOT = 3;
    uint256 private constant STORED_POOL_KEYS_SLOT = 4;
    uint256 private constant REWARDS_GLOBAL_PER_LIQUIDITY_SLOT = 5;
    uint256 private constant TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_SLOT = 6;
    uint256 private constant POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_SLOT = 7;
    uint256 private constant TOTAL_VOTE_WEIGHT_SLOT = 8;
    uint256 private constant EMISSION_GROWTH_GLOBAL_X128_SLOT = 9;
    uint256 private constant EMISSION_RATE_AND_LAST_ACCRUED_SLOT = 10;
    uint256 private constant EMISSION_INITIALIZED_TIME_BITMAP_SLOT = 11;
    uint256 private constant EMISSION_RATE_DELTA_AT_TIME_SLOT = 12;

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
        return uint128(uint256(ve33.sload(_stakeAmountSlot(owner, stakeId))));
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
        return PoolId.wrap(ve33.sload(_votedPoolIdSlot(owner, stakeId)));
    }

    /// @notice Returns per-stake vote and fee accounting for the currently voted pool.
    function vePoolPosition(Ve33 ve33, address owner, StakeId stakeId)
        internal
        view
        returns (Ve33.VePoolPosition memory position)
    {
        StorageSlot slot = _vePoolPositionSlot(owner, stakeId);
        (bytes32 packed, bytes32 feeGrowth0X128Snapshot, bytes32 feeGrowth1X128Snapshot) =
            ve33.sload(slot, _add(slot, 1), _add(slot, 2));

        uint256 packedValue = uint256(packed);
        uint128 weight;
        uint64 swapFee;
        assembly ("memory-safe") {
            weight := packedValue
            swapFee := shr(128, packedValue)
        }
        position.weight = weight;
        position.swapFee = swapFee;
        position.feeGrowth0X128Snapshot = uint256(feeGrowth0X128Snapshot);
        position.feeGrowth1X128Snapshot = uint256(feeGrowth1X128Snapshot);
    }

    /// @notice Returns aggregated voting and fee state for a pool.
    function poolVoteState(Ve33 ve33, PoolId poolId) internal view returns (Ve33.PoolVoteState memory state) {
        StorageSlot slot = _poolMappingSlot(poolId, POOL_VOTE_STATES_SLOT);
        (bytes32 feeGrowth0X128, bytes32 feeGrowth1X128, bytes32 emissionGrowthGlobalX128Snapshot) =
            ve33.sload(slot, _add(slot, 1), _add(slot, 2));
        bytes32 feeWeightSum = ve33.sload(_add(slot, 3));
        bytes32 weight = ve33.sload(_add(slot, 4));

        state.feeGrowth0X128 = uint256(feeGrowth0X128);
        state.feeGrowth1X128 = uint256(feeGrowth1X128);
        state.emissionGrowthGlobalX128Snapshot = uint256(emissionGrowthGlobalX128Snapshot);
        state.feeWeightSum = uint192(uint256(feeWeightSum));
        state.weight = uint128(uint256(weight));
    }

    /// @notice Returns the canonical key recorded for an initialized Ve33 pool.
    function storedPoolKey(Ve33 ve33, PoolId poolId) internal view returns (PoolKey memory key) {
        StorageSlot slot = _poolMappingSlot(poolId, STORED_POOL_KEYS_SLOT);
        (bytes32 token0, bytes32 token1, bytes32 config) = ve33.sload(slot, _add(slot, 1), _add(slot, 2));
        key.token0 = address(uint160(uint256(token0)));
        key.token1 = address(uint160(uint256(token1)));
        key.config = PoolConfig.wrap(config);
    }

    /// @notice Returns global reward growth per unit of in-range liquidity for a pool.
    function rewardsGlobalPerLiquidity(Ve33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(ve33.sload(_poolMappingSlot(poolId, REWARDS_GLOBAL_PER_LIQUIDITY_SLOT)));
    }

    /// @notice Returns reward growth outside an initialized tick.
    function tickRewardsOutsidePerLiquidity(Ve33 ve33, PoolId poolId, int32 tick) internal view returns (uint256) {
        StorageSlot poolSlot = _poolMappingSlot(poolId, TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_SLOT);
        bytes32 tickKey;
        assembly ("memory-safe") {
            tickKey := signextend(3, tick)
        }
        return uint256(ve33.sload(_mappingSlot(tickKey, poolSlot)));
    }

    /// @notice Returns a position reward growth snapshot.
    function positionRewardsSnapshotPerLiquidity(Ve33 ve33, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint256)
    {
        StorageSlot poolSlot = _poolMappingSlot(poolId, POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_SLOT);
        StorageSlot ownerSlot = _mappingSlot(bytes32(uint256(uint160(owner))), poolSlot);
        return uint256(ve33.sload(_mappingSlot(PositionId.unwrap(positionId), ownerSlot)));
    }

    /// @notice Returns total active ve vote weight across all pools.
    function totalVoteWeight(Ve33 ve33) internal view returns (uint256) {
        return uint128(uint256(ve33.sload(bytes32(TOTAL_VOTE_WEIGHT_SLOT))));
    }

    /// @notice Returns accumulated global emission growth per unit of active vote weight.
    function emissionGrowthGlobalX128(Ve33 ve33) internal view returns (uint256) {
        return uint256(ve33.sload(bytes32(EMISSION_GROWTH_GLOBAL_X128_SLOT)));
    }

    /// @notice Returns the current global Q32 emission rate.
    function emissionRate(Ve33 ve33) internal view returns (uint192) {
        return uint192(uint256(ve33.sload(bytes32(EMISSION_RATE_AND_LAST_ACCRUED_SLOT))));
    }

    /// @notice Returns the last timestamp when global emissions were accrued.
    function emissionsLastAccrued(Ve33 ve33) internal view returns (uint64) {
        return uint64(uint256(ve33.sload(bytes32(EMISSION_RATE_AND_LAST_ACCRUED_SLOT))) >> 192);
    }

    /// @notice Returns one global emission initialized-time bitmap word.
    function emissionInitializedTimeBitmap(Ve33 ve33, uint256 word) internal view returns (uint256) {
        return uint256(ve33.sload(_mappingSlot(bytes32(word), _storageSlot(EMISSION_INITIALIZED_TIME_BITMAP_SLOT))));
    }

    /// @notice Returns the scheduled global emission-rate delta at `time`.
    function emissionRateDeltaAtTime(Ve33 ve33, uint64 time) internal view returns (int256) {
        return int256(
            uint256(ve33.sload(_mappingSlot(bytes32(uint256(time)), _storageSlot(EMISSION_RATE_DELTA_AT_TIME_SLOT))))
        );
    }

    function _stakeAmountSlot(address owner, StakeId stakeId) private pure returns (StorageSlot) {
        return _mappingSlot(
            StakeId.unwrap(stakeId), _mappingSlot(bytes32(uint256(uint160(owner))), _storageSlot(STAKE_AMOUNTS_SLOT))
        );
    }

    function _votedPoolIdSlot(address owner, StakeId stakeId) private pure returns (StorageSlot) {
        return _mappingSlot(
            StakeId.unwrap(stakeId), _mappingSlot(bytes32(uint256(uint160(owner))), _storageSlot(VOTED_POOL_IDS_SLOT))
        );
    }

    function _vePoolPositionSlot(address owner, StakeId stakeId) private pure returns (StorageSlot) {
        StorageSlot ownerSlot = _mappingSlot(bytes32(uint256(uint160(owner))), _storageSlot(VE_POOL_POSITIONS_SLOT));
        return _mappingSlot(StakeId.unwrap(stakeId), ownerSlot);
    }

    function _poolMappingSlot(PoolId poolId, uint256 slot) private pure returns (StorageSlot) {
        return _mappingSlot(PoolId.unwrap(poolId), _storageSlot(slot));
    }

    function _mappingSlot(bytes32 key, StorageSlot slot) private pure returns (StorageSlot result) {
        assembly ("memory-safe") {
            mstore(0, key)
            mstore(32, slot)
            result := keccak256(0, 64)
        }
    }

    function _storageSlot(uint256 slot) private pure returns (StorageSlot result) {
        assembly ("memory-safe") {
            result := slot
        }
    }

    function _add(StorageSlot slot, uint256 offset) private pure returns (StorageSlot result) {
        assembly ("memory-safe") {
            result := add(slot, offset)
        }
    }
}
