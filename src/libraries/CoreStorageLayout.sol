// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolId} from "../types/poolId.sol";
import {PositionId} from "../types/positionId.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title Core Storage Layout
/// @notice Library providing functions to compute the storage locations for the Core contract
/// @dev Core uses a custom storage layout to avoid keccak's where possible.
///      For certain storage values, the pool id is used as a base offset and
///      we allocate the following relative offsets (starting from the pool id) as:
///        0: pool state
///        [FPL_OFFSET, FPL_OFFSET + 1]: fees per liquidity
///        [TICKS_OFFSET + MIN_TICK, TICKS_OFFSET + MAX_TICK]: tick info
///        [FPL_OUTSIDE_OFFSET_VALUE0 + MIN_TICK, FPL_OUTSIDE_OFFSET_VALUE0 + MAX_TICK]: fees per liquidity outside (value0)
///        [FPL_OUTSIDE_OFFSET_VALUE0 + FPL_OUTSIDE_OFFSET_VALUE1 + MIN_TICK, FPL_OUTSIDE_OFFSET_VALUE0 + FPL_OUTSIDE_OFFSET_VALUE1 + MAX_TICK]: fees per liquidity outside (value1)
///        [BITMAPS_OFFSET + FIRST_BITMAP_WORD, BITMAPS_OFFSET + LAST_BITMAP_WORD]: tick bitmaps
library CoreStorageLayout {
    /// @dev Generated using: cast keccak "CoreStorageLayout#FPL_OFFSET"
    uint256 internal constant FPL_OFFSET = 0xb09b03866d96933565a9435bfb511c8ac5b2be454285ca331201452704799f72;
    /// @dev Generated using: cast keccak "CoreStorageLayout#TICKS_OFFSET"
    uint256 internal constant TICKS_OFFSET = 0x435a5eb89a296820174331cf5a3902d9fca683928d56726d8e7acd6efb28c568;
    /// @dev Generated using: cast keccak "CoreStorageLayout#FPL_OUTSIDE_OFFSET_VALUE0"
    uint256 internal constant FPL_OUTSIDE_OFFSET_VALUE0 =
        0x5695060fdb9cfea656f872ae4887221aff7dbfefc45eaf753e4e70cdfb5cd19c;
    /// @dev Generated using: cast keccak "CoreStorageLayout#FPL_OUTSIDE_OFFSET_VALUE1"
    uint256 internal constant FPL_OUTSIDE_OFFSET_VALUE1 =
        0x7a2a03fc08af3dae7869678617dc8abe8f15a3b719b37ba108dba879571f8b02;
    /// @dev Generated using: cast keccak "CoreStorageLayout#BITMAPS_OFFSET"
    uint256 internal constant BITMAPS_OFFSET = 0x3def450d0010a2fef515ce5eba4b363b5a0f42fdd4c53e1c737975db05a2e3a5;

    /// @notice Computes the storage slot containing information on whether an extension is registered
    /// @param extension The extension address to check
    /// @return slot The storage slot in the Core contract
    function isExtensionRegisteredSlot(address extension) internal pure returns (StorageSlot slot) {
        assembly ("memory-safe") {
            mstore(0, extension)
            mstore(32, 0)
            slot := keccak256(0, 64)
        }
    }

    /// @notice Computes the storage slot of the current state of a pool
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the Core contract
    function poolStateSlot(PoolId poolId) internal pure returns (StorageSlot slot) {
        slot = StorageSlot.wrap(PoolId.unwrap(poolId));
    }

    /// @notice Computes the storage slots of the current global fees per liquidity of a pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first of two consecutive storage slots in the Core contract
    function poolFeesPerLiquiditySlot(PoolId poolId) internal pure returns (StorageSlot firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, FPL_OFFSET)
        }
    }

    /// @notice Computes the storage slot of tick information for a specific tick in a pool
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return slot The storage slot in the Core contract
    function poolTicksSlot(PoolId poolId, int32 tick) internal pure returns (StorageSlot slot) {
        assembly ("memory-safe") {
            slot := add(poolId, add(tick, TICKS_OFFSET))
        }
    }

    /// @notice Computes the storage slots of the outside fees of a pool for a given tick
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return firstSlot The first storage slot in the Core contract
    /// @return secondSlot The second storage slot in the Core contract
    function poolTickFeesPerLiquidityOutsideSlot(PoolId poolId, int32 tick)
        internal
        pure
        returns (StorageSlot firstSlot, StorageSlot secondSlot)
    {
        assembly ("memory-safe") {
            firstSlot := add(poolId, add(FPL_OUTSIDE_OFFSET_VALUE0, tick))
            secondSlot := add(firstSlot, FPL_OUTSIDE_OFFSET_VALUE1)
        }
    }

    /// @notice Computes the first storage slot of the tick bitmaps for a specific pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first storage slot in the Core contract
    function tickBitmapsSlot(PoolId poolId) internal pure returns (StorageSlot firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, BITMAPS_OFFSET)
        }
    }

    /// @notice Computes the first storage slot of the position data for a specific position in a pool
    /// @param poolId The unique identifier for the pool
    /// @param owner The position owner
    /// @param positionId The unique identifier for the position
    /// @return firstSlot The first of three consecutive storage slots in the Core contract
    function poolPositionsSlot(PoolId poolId, address owner, PositionId positionId)
        internal
        pure
        returns (StorageSlot firstSlot)
    {
        assembly ("memory-safe") {
            mstore(0, positionId)
            firstSlot := add(keccak256(0, 32), add(poolId, owner))
        }
    }

    /// @notice Computes the storage slot for saved balances
    /// @param owner The owner of the saved balances
    /// @param token0 The first token address
    /// @param token1 The second token address
    /// @param salt The salt used for the saved balance key
    /// @return slot The storage slot in the Core contract
    function savedBalancesSlot(address owner, address token0, address token1, bytes32 salt)
        internal
        pure
        returns (StorageSlot slot)
    {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, owner)
            mstore(add(free, 0x20), token0)
            mstore(add(free, 0x40), token1)
            mstore(add(free, 0x60), salt)
            slot := keccak256(free, 128)
        }
    }
}
