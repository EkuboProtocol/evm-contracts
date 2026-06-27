// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {PoolId} from "../types/poolId.sol";
import {PositionId} from "../types/positionId.sol";
import {StakeId} from "../types/stakeId.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title Ve33 Storage Layout
/// @notice Library providing functions to compute storage locations for the Ve33 contract.
/// @dev Ve33 has no declared mutable storage; all state is accessed through these slots.
library Ve33StorageLayout {
    uint256 internal constant TOTAL_VOTE_WEIGHT_SLOT = 0;
    uint256 internal constant EMISSION_GROWTH_GLOBAL_X128_SLOT = 1;
    uint256 internal constant EMISSION_RATE_AND_LAST_ACCRUED_SLOT = 2;

    /// @dev Generated using: cast keccak "Ve33StorageLayout#STAKE_AMOUNTS"
    bytes32 internal constant STAKE_AMOUNTS_OFFSET = 0xf29d69126430259138de154203ff5fc6f1483dd3f8a828abafae1b34ab95096d;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#VOTED_POOL_IDS"
    bytes32 internal constant VOTED_POOL_IDS_OFFSET =
        0x9fe4011cb2802dbdb1920c49e91d91623fe459ad47ab879023a04bd66f14db7b;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#VE_POOL_VOTES"
    bytes32 internal constant VE_POOL_VOTES_OFFSET = 0x8765e5a95ee611ec54f6dbea00f7e39e5183919c05deb57f864690aa70f7da5f;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#VE_POOL_FEE_GROWTH_SNAPSHOTS"
    bytes32 internal constant VE_POOL_FEE_GROWTH_SNAPSHOTS_OFFSET =
        0x68cfbdb1fd71eed41f8ef8e18b2f4850238033554ef4c9fb587cb198a1d7c0db;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#POOL_EMISSION_GROWTH_GLOBAL_X128_SNAPSHOTS"
    bytes32 internal constant POOL_EMISSION_GROWTH_GLOBAL_X128_SNAPSHOTS_OFFSET =
        0x8695bdcbbe8669aa39c45810141041cc083bec67dfefcbff155befe7bc3d5c78;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#POOL_FEE_STATES"
    bytes32 internal constant POOL_FEE_STATES_OFFSET =
        0x2ddd369911f3df37f381a02a272e932049cecd3447d14d787a8a8fd0418544ce;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#POOL_TOTAL_WEIGHTS"
    bytes32 internal constant POOL_TOTAL_WEIGHTS_OFFSET =
        0x3a93fa7e86b9b605f8975a2840f6d3e652f72249743bc849ba2127796588c5ff;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#POOL_FEE_GROWTH"
    bytes32 internal constant POOL_FEE_GROWTH_OFFSET =
        0xc961ee626d9b17659189fec087c4e08068c036fe14a263a6d519de462aec1bc1;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#REWARDS_GLOBAL_PER_LIQUIDITY"
    bytes32 internal constant REWARDS_GLOBAL_PER_LIQUIDITY_OFFSET =
        0x592f7fa177f0ee5c03ca99778020e3e8b4741944c954a14a7bb2b99beb3be2b6;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY"
    bytes32 internal constant POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_OFFSET =
        0x05c92b51a0150d6cb1a65a8641ad9d04483fe2cda95f0a06aee0912bb08bf239;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#TICK_REWARDS_OUTSIDE_PER_LIQUIDITY"
    bytes32 internal constant TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_OFFSET =
        0x8fd6af9bf6ebcb09053e06f51348e40bbbbc5dd36cff08907349f451d91d3f3e;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#EMISSION_INITIALIZED_TIME_BITMAP"
    bytes32 internal constant EMISSION_INITIALIZED_TIME_BITMAP_OFFSET =
        0xcbda55eea3b6e763641ac8c7b77d141aede003b005b32d3d8a8492575071fa86;
    /// @dev Generated using: cast keccak "Ve33StorageLayout#EMISSION_RATE_DELTA_AT_TIME"
    bytes32 internal constant EMISSION_RATE_DELTA_AT_TIME_OFFSET =
        0x5d917ce22176bd3c07b047dddfc13911feb451de3677a1e7b46141594cd27037;

    /// @notice Computes the storage slot for a staked amount.
    function stakeAmountSlot(address owner, StakeId stakeId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(bytes32(uint256(uint160(owner))), StakeId.unwrap(stakeId), STAKE_AMOUNTS_OFFSET)
        );
    }

    /// @notice Computes the storage slot for the pool currently voted on by a stake.
    function votedPoolIdSlot(address owner, StakeId stakeId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(bytes32(uint256(uint160(owner))), StakeId.unwrap(stakeId), VOTED_POOL_IDS_OFFSET)
        );
    }

    /// @notice Computes the storage slot for a stake's active ve pool vote.
    function vePoolVoteSlot(address owner, StakeId stakeId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(bytes32(uint256(uint160(owner))), StakeId.unwrap(stakeId), VE_POOL_VOTES_OFFSET)
        );
    }

    /// @notice Computes the first storage slot for a stake's pool fee-growth snapshot.
    function vePoolFeeGrowthSnapshotSlot(address owner, StakeId stakeId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(
                bytes32(uint256(uint160(owner))), StakeId.unwrap(stakeId), VE_POOL_FEE_GROWTH_SNAPSHOTS_OFFSET
            )
        );
    }

    /// @notice Computes the storage slot for a pool's emission-growth snapshot.
    function poolEmissionGrowthGlobalX128SnapshotSlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(PoolId.unwrap(poolId), POOL_EMISSION_GROWTH_GLOBAL_X128_SNAPSHOTS_OFFSET)
        );
    }

    /// @notice Computes the storage slot for a pool's fee-weight sum and cached swap fee.
    function poolFeeStateSlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(PoolId.unwrap(poolId), POOL_FEE_STATES_OFFSET));
    }

    /// @notice Computes the storage slot for a pool's total active vote weight.
    function poolTotalWeightSlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(PoolId.unwrap(poolId), POOL_TOTAL_WEIGHTS_OFFSET));
    }

    /// @notice Computes the first storage slot for pool fee growth per unit of vote weight.
    function poolFeeGrowthSlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(PoolId.unwrap(poolId), POOL_FEE_GROWTH_OFFSET));
    }

    /// @notice Computes the storage slot for global reward-token growth per unit of liquidity.
    function rewardsGlobalPerLiquiditySlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(PoolId.unwrap(poolId), REWARDS_GLOBAL_PER_LIQUIDITY_OFFSET));
    }

    /// @notice Computes the storage slot for reward growth outside one initialized tick.
    function tickRewardsOutsidePerLiquiditySlot(PoolId poolId, int32 tick) internal pure returns (StorageSlot slot) {
        bytes32 tickKey;
        assembly ("memory-safe") {
            tickKey := signextend(3, tick)
        }
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(PoolId.unwrap(poolId), tickKey, TICK_REWARDS_OUTSIDE_PER_LIQUIDITY_OFFSET)
        );
    }

    /// @notice Computes the storage slot for a position reward growth snapshot.
    function positionRewardsSnapshotPerLiquiditySlot(PoolId poolId, address owner, PositionId positionId)
        internal
        pure
        returns (StorageSlot slot)
    {
        slot = StorageSlot.wrap(
            EfficientHashLib.hash(
                PoolId.unwrap(poolId),
                bytes32(uint256(uint160(owner))),
                PositionId.unwrap(positionId),
                POSITION_REWARDS_SNAPSHOT_PER_LIQUIDITY_OFFSET
            )
        );
    }

    /// @notice Computes the storage slot for total active ve vote weight.
    function totalVoteWeightSlot() internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(bytes32(TOTAL_VOTE_WEIGHT_SLOT));
    }

    /// @notice Computes the storage slot for accumulated global emission growth.
    function emissionGrowthGlobalX128Slot() internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(bytes32(EMISSION_GROWTH_GLOBAL_X128_SLOT));
    }

    /// @notice Computes the storage slot that packs emission rate and last-accrued time.
    function emissionRateAndLastAccruedSlot() internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(bytes32(EMISSION_RATE_AND_LAST_ACCRUED_SLOT));
    }

    /// @notice Computes the storage slot for one initialized emission-time bitmap word.
    function emissionInitializedTimeBitmapSlot(uint256 word) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(word, uint256(EMISSION_INITIALIZED_TIME_BITMAP_OFFSET)));
    }

    /// @notice Computes the storage slot for the scheduled emission-rate delta at a time.
    function emissionRateDeltaAtTimeSlot(uint256 time) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(EfficientHashLib.hash(time, uint256(EMISSION_RATE_DELTA_AT_TIME_OFFSET)));
    }
}
