// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolId} from "../types/poolId.sol";
import {PositionId} from "../types/positionId.sol";

/// @title Core Storage Slot Library
/// @notice Library providing functions to compute all storage slots used in Core
/// @dev Core uses a custom storage layout to avoid keccak's where possible.
///      For certain storage values, the pool id is used as a base offset and
///      we allocate the following relative offsets (starting from the pool id) as:
///        0: pool state
///        1 + 2: fees per liquidity
///        [TICKS_OFFSET + MIN_TICK, TICKS_OFFSET + MAX_TICK]: tick info
///        [FPL_OUTSIDE_OFFSET + MIN_TICK, 2 * FPL_OUTSIDE_OFFSET + MAX_TICK]: fees per liquidity outside
///        [BITMAPS_OFFSET + FIRST_BITMAP_WORD, BITMAPS_OFFSET + LAST_BITMAP_WORD]: tick bitmaps
library CoreStorageSlotLib {
    uint256 internal constant TICKS_OFFSET = 0xffffffff;
    uint256 internal constant FPL_OUTSIDE_OFFSET = 0xffffffffff;
    uint256 internal constant BITMAPS_OFFSET = 0xffffffffffff;

    /// @notice Computes the storage slot containing information on whether an extension is registered
    /// @param extension The extension address to check
    /// @return slot The storage slot in the Core contract
    function isExtensionRegisteredSlot(address extension) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0, extension)
            mstore(32, 0)
            slot := keccak256(0, 64)
        }
    }

    /// @notice Computes the storage slot of the current state of a pool
    /// @param poolId The unique identifier for the pool
    /// @return slot The storage slot in the Core contract
    function poolStateSlot(PoolId poolId) internal pure returns (bytes32 slot) {
        slot = PoolId.unwrap(poolId);
    }

    /// @notice Computes the storage slots of the current fees of a pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first of two consecutive storage slots in the Core contract
    function poolFeesPerLiquiditySlot(PoolId poolId) internal pure returns (bytes32 firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, 1)
        }
    }

    /// @notice Computes the storage slot of tick information for a specific tick in a pool
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return slot The storage slot in the Core contract
    function poolTicksSlot(PoolId poolId, int32 tick) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := add(poolId, add(tick, TICKS_OFFSET))
        }
    }

    /// @notice Computes the storage slot of the current state of a pool
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return firstSlot The first storage slot in the Core contract
    /// @return secondSlot The second storage slot in the Core contract
    function poolTickFeesPerLiquidityOutsideSlot(PoolId poolId, int32 tick)
        internal
        pure
        returns (bytes32 firstSlot, bytes32 secondSlot)
    {
        assembly ("memory-safe") {
            firstSlot := add(poolId, add(FPL_OUTSIDE_OFFSET, tick))
            secondSlot := add(firstSlot, FPL_OUTSIDE_OFFSET)
        }
    }

    /// @notice Computes the first storage slot of the tick bitmaps for a specific pool
    /// @param poolId The unique identifier for the pool
    /// @return firstSlot The first storage slot in the Core contract
    function tickBitmapsSlot(PoolId poolId) internal pure returns (bytes32 firstSlot) {
        assembly ("memory-safe") {
            firstSlot := add(poolId, BITMAPS_OFFSET)
        }
    }

    /// @notice Computes the storage slot of the position data for a specific position in a pool
    /// @param poolId The unique identifier for the pool
    /// @param owner The position owner
    /// @param positionId The unique identifier for the position
    /// @return firstSlot The first of three consecutive storage slots in the Core contract
    function poolPositionsSlot(PoolId poolId, address owner, PositionId positionId)
        internal
        pure
        returns (bytes32 firstSlot)
    {
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, positionId)
            firstSlot := add(keccak256(0, 64), owner)
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
        returns (bytes32 slot)
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
