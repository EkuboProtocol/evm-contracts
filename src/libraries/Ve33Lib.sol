// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {
    Ve33,
    VE33_ADD_REWARDS,
    VE33_CLAIM_POOL_FEES,
    VE33_CLAIM_REWARDS,
    VE33_DONATE_REWARDS,
    VE33_FUND_EMISSIONS,
    VE33_MAX_STAKE_DURATION,
    VE33_MOVE_STAKE,
    VE33_STAKE,
    VE33_SWAP,
    VE33_TRIGGER_POOL_EMISSIONS,
    VE33_UNSTAKE,
    Ve33RewardPoolState
} from "../extensions/Ve33.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

/// @title Ve33 Library
/// @notice Exposed-storage readers for Ve33 state.
/// @dev Slot constants match Ve33's declared storage layout. Ve33 inherits only storage-less bases.
library Ve33Lib {
    using ExposedStorageLib for IExposedStorage;
    using FlashAccountantLib for *;

    uint256 private constant STAKE_AMOUNTS_SLOT = 0;
    uint256 private constant VOTED_POOLS_SLOT = 1;
    uint256 private constant VE_POOL_POSITIONS_SLOT = 2;
    uint256 private constant POOL_VOTE_STATES_SLOT = 3;
    uint256 private constant POOL_REWARD_STATE_SLOT = 4;
    uint256 private constant REWARDS_GLOBAL_PER_LIQUIDITY_SLOT = 5;
    uint256 private constant TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_SLOT = 6;
    uint256 private constant POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_SLOT = 7;
    uint256 private constant INITIALIZED_TIME_BITMAP_SLOT = 8;
    uint256 private constant REWARD_RATE_DELTA_AT_TIME_SLOT = 9;
    uint256 private constant TOTAL_VOTE_WEIGHT_SLOT = 10;
    uint256 private constant TOTAL_VOTE_SECONDS_SLOT = 11;
    uint256 private constant TOTAL_VOTE_SECONDS_LAST_ACCRUED_SLOT = 12;
    uint256 private constant EMISSION_RESERVE_SLOT = 13;
    uint256 private constant UNALLOCATED_EMISSIONS_SLOT = 14;
    uint256 private constant EMISSION_RATE_SLOT = 15;
    uint256 private constant EMISSIONS_LAST_ACCRUED_SLOT = 16;
    uint256 private constant NEXT_EMISSION_EVENT_INDEX_SLOT = 17;
    uint256 private constant EMISSION_EVENT_TIMES_SLOT = 18;
    uint256 private constant EMISSION_RATE_DECREASE_AT_SLOT = 19;

    /// @notice Duration of each global and per-pool emission stream.
    uint256 internal constant EMISSION_DURATION = 7 days;

    /// @notice Forwards raw Ve33 action data through Core.
    function forward(ICore core, Ve33 ve33, bytes memory data) internal returns (bytes memory result) {
        result = core.forward(address(ve33), data);
    }

    /// @notice Executes a Ve33 forwarded swap through Core.
    function swap(ICore core, Ve33 ve33, PoolKey memory poolKey, SwapParameters params)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(
            forward(core, ve33, abi.encode(VE33_SWAP, poolKey, params)), (PoolBalanceUpdate, PoolState)
        );
    }

    /// @notice Claims LP rewards for a Ve33 position through Core.
    function claimRewards(ICore core, Ve33 ve33, PoolKey memory poolKey, PositionId positionId, address recipient)
        internal
        returns (uint256 amount)
    {
        amount =
            abi.decode(forward(core, ve33, abi.encode(VE33_CLAIM_REWARDS, poolKey, positionId, recipient)), (uint256));
    }

    /// @notice Donates stake-token rewards to eligible Ve33 LP liquidity through Core.
    function donateRewards(ICore core, Ve33 ve33, PoolKey memory poolKey, uint128 amount)
        internal
        returns (uint128 donated)
    {
        donated = abi.decode(forward(core, ve33, abi.encode(VE33_DONATE_REWARDS, poolKey, amount)), (uint128));
    }

    /// @notice Schedules stake-token LP rewards for a Ve33 pool through Core.
    function addRewards(
        ICore core,
        Ve33 ve33,
        PoolKey memory poolKey,
        uint64 startTime,
        uint64 endTime,
        uint224 rewardRate
    ) internal returns (uint224 amount) {
        amount = abi.decode(
            forward(core, ve33, abi.encode(VE33_ADD_REWARDS, poolKey, startTime, endTime, rewardRate)), (uint224)
        );
    }

    /// @notice Stakes tokens into Ve33 through Core.
    function stake(ICore core, Ve33 ve33, bytes32 salt, uint64 endTime, uint128 amount)
        internal
        returns (uint128 staked)
    {
        staked = abi.decode(forward(core, ve33, abi.encode(VE33_STAKE, salt, endTime, amount)), (uint128));
    }

    /// @notice Unstakes tokens from Ve33 through Core.
    function unstake(ICore core, Ve33 ve33, bytes32 salt, uint64 endTime, uint128 amount)
        internal
        returns (uint128 unstaked)
    {
        unstaked = abi.decode(forward(core, ve33, abi.encode(VE33_UNSTAKE, salt, endTime, amount)), (uint128));
    }

    /// @notice Moves stake between two Ve33 stake keys through Core.
    function moveStake(
        ICore core,
        Ve33 ve33,
        bytes32 fromSalt,
        uint64 fromEndTime,
        bytes32 toSalt,
        uint64 toEndTime,
        uint128 amount
    ) internal returns (uint128 moved) {
        moved = abi.decode(
            forward(core, ve33, abi.encode(VE33_MOVE_STAKE, fromSalt, fromEndTime, toSalt, toEndTime, amount)),
            (uint128)
        );
    }

    /// @notice Claims pool fees for a Ve33 stake through Core.
    function claimPoolFees(ICore core, Ve33 ve33, Ve33.StakeKey memory stakeKey, PoolKey memory poolKey)
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            forward(core, ve33, abi.encode(VE33_CLAIM_POOL_FEES, stakeKey, poolKey)), (uint128, uint128)
        );
    }

    /// @notice Funds global Ve33 emissions through Core.
    function fundEmissions(ICore core, Ve33 ve33, uint128 amount) internal returns (uint224 rate, uint64 end) {
        (rate, end) = abi.decode(forward(core, ve33, abi.encode(VE33_FUND_EMISSIONS, amount)), (uint224, uint64));
    }

    /// @notice Assigns a voted pool's share of global emissions to LP rewards through Core.
    function triggerPoolEmissions(ICore core, Ve33 ve33, PoolKey memory poolKey) internal returns (uint224 amount) {
        amount = abi.decode(forward(core, ve33, abi.encode(VE33_TRIGGER_POOL_EMISSIONS, poolKey)), (uint224));
    }

    /// @notice Returns stake for `(owner, salt, endTime)`.
    function stakeAmount(Ve33 ve33, address owner, bytes32 salt, uint64 endTime) internal view returns (uint128) {
        return uint128(uint256(_target(ve33).sload(_stakeAmountSlot(owner, salt, endTime))));
    }

    /// @notice Returns stake for a canonical stake key.
    function stakeAmount(Ve33 ve33, Ve33.StakeKey memory stakeKey) internal view returns (uint128) {
        return stakeAmount(ve33, stakeKey.owner, stakeKey.salt, stakeKey.endTime);
    }

    /// @notice Returns current linearly decaying voting power for a canonical stake key.
    function votingPower(Ve33 ve33, Ve33.StakeKey memory stakeKey) internal view returns (uint256 power) {
        if (block.timestamp >= stakeKey.endTime) return 0;

        unchecked {
            power =
                (uint256(stakeAmount(ve33, stakeKey)) * (stakeKey.endTime - block.timestamp)) / VE33_MAX_STAKE_DURATION;
        }
    }

    /// @notice Returns the number of pools currently voted on by `stakeId`.
    function votedPoolsLength(Ve33 ve33, bytes32 stakeId) internal view returns (uint256) {
        return uint256(_target(ve33).sload(_votedPoolsSlot(stakeId)));
    }

    /// @notice Returns the voted pool id at `index` for `stakeId`.
    function votedPool(Ve33 ve33, bytes32 stakeId, uint256 index) internal view returns (PoolId) {
        StorageSlot arraySlot = _votedPoolsSlot(stakeId);
        return PoolId.wrap(_target(ve33).sload(_arrayElementSlot(arraySlot, index)));
    }

    /// @notice Returns per-lock vote and fee accounting for one pool.
    function vePoolPosition(Ve33 ve33, bytes32 stakeId, PoolId poolId)
        internal
        view
        returns (Ve33.VePoolPosition memory position)
    {
        StorageSlot slot = _vePoolPositionSlot(stakeId, poolId);
        (bytes32 packed, bytes32 feeGrowth0X128, bytes32 feeGrowth1X128) =
            _target(ve33).sload(slot, _add(slot, 1), _add(slot, 2));
        (bytes32 accrued0, bytes32 accrued1) = _target(ve33).sload(_add(slot, 3), _add(slot, 4));

        uint256 packedValue = uint256(packed);
        uint128 weight;
        uint64 swapFee;
        assembly ("memory-safe") {
            weight := packedValue
            swapFee := shr(128, packedValue)
        }
        position.weight = weight;
        position.swapFee = swapFee;
        position.feeGrowth0X128 = uint256(feeGrowth0X128);
        position.feeGrowth1X128 = uint256(feeGrowth1X128);
        position.accrued0 = uint256(accrued0);
        position.accrued1 = uint256(accrued1);
    }

    /// @notice Returns aggregated voting and fee state for a pool.
    function poolVoteState(Ve33 ve33, PoolId poolId) internal view returns (Ve33.PoolVoteState memory state) {
        StorageSlot slot = _poolMappingSlot(poolId, POOL_VOTE_STATES_SLOT);
        (bytes32 weight, bytes32 voteSeconds, bytes32 feeGrowth0X128) =
            _target(ve33).sload(slot, _add(slot, 1), _add(slot, 2));
        (bytes32 feeGrowth1X128, bytes32 feeWeightSum, bytes32 packed) =
            _target(ve33).sload(_add(slot, 3), _add(slot, 4), _add(slot, 5));

        uint256 packedValue = uint256(packed);
        uint64 lastAccrued;
        uint64 swapFee;
        uint64 defaultSwapFee;
        assembly ("memory-safe") {
            lastAccrued := packedValue
            swapFee := shr(64, packedValue)
            defaultSwapFee := shr(128, packedValue)
        }
        state.weight = uint256(weight);
        state.voteSeconds = uint256(voteSeconds);
        state.feeGrowth0X128 = uint256(feeGrowth0X128);
        state.feeGrowth1X128 = uint256(feeGrowth1X128);
        state.feeWeightSum = uint256(feeWeightSum);
        state.lastAccrued = lastAccrued;
        state.swapFee = swapFee;
        state.defaultSwapFee = defaultSwapFee;
    }

    /// @notice Returns packed reward-stream state for a pool.
    function poolRewardState(Ve33 ve33, PoolId poolId) internal view returns (Ve33RewardPoolState) {
        return Ve33RewardPoolState.wrap(_target(ve33).sload(_poolMappingSlot(poolId, POOL_REWARD_STATE_SLOT)));
    }

    /// @notice Returns global reward growth per unit of in-range liquidity for a pool.
    function rewardsGlobalPerLiquidity(Ve33 ve33, PoolId poolId) internal view returns (uint256) {
        return uint256(_target(ve33).sload(_poolMappingSlot(poolId, REWARDS_GLOBAL_PER_LIQUIDITY_SLOT)));
    }

    /// @notice Returns reward growth outside an initialized tick.
    function tickRewardsOutsidePerLiquidity(Ve33 ve33, PoolId poolId, int32 tick) internal view returns (uint256) {
        StorageSlot poolSlot = _poolMappingSlot(poolId, TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_SLOT);
        bytes32 tickKey;
        assembly ("memory-safe") {
            tickKey := signextend(3, tick)
        }
        return uint256(_target(ve33).sload(_mappingSlot(tickKey, poolSlot)));
    }

    /// @notice Returns a position reward growth snapshot.
    function positionRewardsSnapshotPerLiquidity(Ve33 ve33, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint256)
    {
        StorageSlot poolSlot = _poolMappingSlot(poolId, POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_SLOT);
        StorageSlot ownerSlot = _mappingSlot(bytes32(uint256(uint160(owner))), poolSlot);
        return uint256(_target(ve33).sload(_mappingSlot(PositionId.unwrap(positionId), ownerSlot)));
    }

    /// @notice Returns an initialized reward-time bitmap word for a pool.
    function initializedTimeBitmap(Ve33 ve33, PoolId poolId, uint256 word) internal view returns (uint256) {
        StorageSlot poolSlot = _poolMappingSlot(poolId, INITIALIZED_TIME_BITMAP_SLOT);
        return uint256(_target(ve33).sload(_mappingSlot(bytes32(word), poolSlot)));
    }

    /// @notice Returns a scheduled reward-rate delta for a pool and time.
    function rewardRateDeltaAtTime(Ve33 ve33, PoolId poolId, uint256 time) internal view returns (int256) {
        StorageSlot poolSlot = _poolMappingSlot(poolId, REWARD_RATE_DELTA_AT_TIME_SLOT);
        return int256(uint256(_target(ve33).sload(_mappingSlot(bytes32(time), poolSlot))));
    }

    /// @notice Returns total active ve vote weight across all pools.
    function totalVoteWeight(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(TOTAL_VOTE_WEIGHT_SLOT)));
    }

    /// @notice Returns accrued time-weighted vote weight across all pools.
    function totalVoteSeconds(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(TOTAL_VOTE_SECONDS_SLOT)));
    }

    /// @notice Returns the last timestamp when total vote seconds were accrued.
    function totalVoteSecondsLastAccrued(Ve33 ve33) internal view returns (uint64) {
        return uint64(uint256(_target(ve33).sload(bytes32(TOTAL_VOTE_SECONDS_LAST_ACCRUED_SLOT))));
    }

    /// @notice Returns funded emissions not yet paid into pool reward schedules.
    function emissionReserve(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(EMISSION_RESERVE_SLOT)));
    }

    /// @notice Returns accrued emissions not yet assigned to any pool.
    function unallocatedEmissions(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(UNALLOCATED_EMISSIONS_SLOT)));
    }

    /// @notice Returns the current global Q32 emission rate.
    function emissionRate(Ve33 ve33) internal view returns (uint224) {
        return uint224(uint256(_target(ve33).sload(bytes32(EMISSION_RATE_SLOT))));
    }

    /// @notice Returns the last timestamp when global emissions were accrued.
    function emissionsLastAccrued(Ve33 ve33) internal view returns (uint64) {
        return uint64(uint256(_target(ve33).sload(bytes32(EMISSIONS_LAST_ACCRUED_SLOT))));
    }

    /// @notice Returns the next unprocessed index in the emission event array.
    function nextEmissionEventIndex(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(NEXT_EMISSION_EVENT_INDEX_SLOT)));
    }

    /// @notice Returns the number of stored emission event times.
    function emissionEventTimesLength(Ve33 ve33) internal view returns (uint256) {
        return uint256(_target(ve33).sload(bytes32(EMISSION_EVENT_TIMES_SLOT)));
    }

    /// @notice Returns an emission event time by index.
    function emissionEventTime(Ve33 ve33, uint256 index) internal view returns (uint64) {
        bytes32 baseSlot = _dynamicArrayDataSlot(_storageSlot(EMISSION_EVENT_TIMES_SLOT));
        bytes32 value = _target(ve33).sload(bytes32(uint256(baseSlot) + (index / 4)));
        uint256 shift = (index % 4) * 64;
        uint64 eventTime;
        assembly ("memory-safe") {
            eventTime := shr(shift, value)
        }
        return eventTime;
    }

    /// @notice Returns an emission event time by index.
    function emissionEventTimes(Ve33 ve33, uint256 index) internal view returns (uint64) {
        return emissionEventTime(ve33, index);
    }

    /// @notice Returns the scheduled global emission-rate decrease at `time`.
    function emissionRateDecreaseAt(Ve33 ve33, uint64 time) internal view returns (uint224) {
        return uint224(
            uint256(
                _target(ve33).sload(_mappingSlot(bytes32(uint256(time)), _storageSlot(EMISSION_RATE_DECREASE_AT_SLOT)))
            )
        );
    }

    function _target(Ve33 ve33) private pure returns (IExposedStorage) {
        return IExposedStorage(address(ve33));
    }

    function _stakeAmountSlot(address owner, bytes32 salt, uint64 endTime) private pure returns (StorageSlot) {
        return _mappingSlot(
            bytes32(uint256(endTime)),
            _mappingSlot(salt, _mappingSlot(bytes32(uint256(uint160(owner))), _storageSlot(STAKE_AMOUNTS_SLOT)))
        );
    }

    function _votedPoolsSlot(bytes32 stakeId) private pure returns (StorageSlot) {
        return _mappingSlot(stakeId, _storageSlot(VOTED_POOLS_SLOT));
    }

    function _vePoolPositionSlot(bytes32 stakeId, PoolId poolId) private pure returns (StorageSlot) {
        return _mappingSlot(PoolId.unwrap(poolId), _mappingSlot(stakeId, _storageSlot(VE_POOL_POSITIONS_SLOT)));
    }

    function _poolMappingSlot(PoolId poolId, uint256 slot) private pure returns (StorageSlot) {
        return _mappingSlot(PoolId.unwrap(poolId), _storageSlot(slot));
    }

    function _arrayElementSlot(StorageSlot arraySlot, uint256 index) private pure returns (StorageSlot slot) {
        bytes32 baseSlot = _dynamicArrayDataSlot(arraySlot);
        return _storageSlot(uint256(baseSlot) + index);
    }

    function _dynamicArrayDataSlot(StorageSlot arraySlot) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, arraySlot)
            result := keccak256(0, 32)
        }
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
