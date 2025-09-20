// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";

/// @title Core Library
/// @notice Library providing common storage getters for external contracts
/// @dev These functions access Core contract storage directly for gas efficiency
library CoreLib {
    using ExposedStorageLib for *;

    /// @notice Checks if an extension is registered with the core contract
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param extension The extension address to check
    /// @return registered True if the extension is registered
    function isExtensionRegistered(ICore core, address extension) internal view returns (bool registered) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, extension)
            mstore(32, 0)
            key := keccak256(0, 64)
        }

        registered = uint256(core.sload(key)) != 0;
    }

    /// @notice Gets the current state of a pool
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @return state The current state of the pool
    function poolState(ICore core, bytes32 poolId) internal view returns (PoolState state) {
        state = PoolState.wrap(core.sload(poolId));
    }

    /// @notice Gets position data for a specific position in a pool
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @param positionId The unique identifier for the position
    /// @return position The position data including liquidity and fees
    function poolPositions(ICore core, bytes32 poolId, address owner, PositionId positionId)
        internal
        view
        returns (Position memory position)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 2)
            let b := keccak256(0, 64)
            mstore(0, owner)
            mstore(32, b)
            b := keccak256(0, 64)
            mstore(0, positionId)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        (bytes32 v0, bytes32 v1, bytes32 v2) = core.sload(key, bytes32(uint256(key) + 1), bytes32(uint256(key) + 2));

        position.liquidity = uint128(uint256(v0));
        position.feesPerLiquidityInsideLast = FeesPerLiquidity(uint256(v1), uint256(v2));
    }

    /// @notice Calculates the storage slot for saved balances
    /// @dev Used internally to compute the correct storage location
    /// @param owner The owner of the saved balances
    /// @param token0 The first token address
    /// @param token1 The second token address
    /// @param salt The salt used for the saved balance key
    /// @return slot The storage slot for the saved balances
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

    /// @notice Gets saved balances for a specific owner and token pair
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param owner The owner of the saved balances
    /// @param token0 The first token address
    /// @param token1 The second token address
    /// @param salt The salt used for the saved balance key
    /// @return savedBalance0 The saved balance of token0
    /// @return savedBalance1 The saved balance of token1
    function savedBalances(ICore core, address owner, address token0, address token1, bytes32 salt)
        internal
        view
        returns (uint128 savedBalance0, uint128 savedBalance1)
    {
        bytes32 key = savedBalancesSlot(owner, token0, token1, salt);

        uint256 value = uint256(core.sload(key));

        savedBalance0 = uint128(value >> 128);
        savedBalance1 = uint128(value);
    }

    /// @notice Gets tick information for a specific tick in a pool
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return liquidityDelta The liquidity change when crossing this tick
    /// @return liquidityNet The net liquidity above this tick
    function poolTicks(ICore core, bytes32 poolId, int32 tick)
        internal
        view
        returns (int128 liquidityDelta, uint128 liquidityNet)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 3)
            let b := keccak256(0, 64)
            mstore(0, tick)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        bytes32 data = core.sload(key);

        // takes only least significant 128 bits
        liquidityDelta = int128(uint128(uint256(data)));
        // takes only most significant 128 bits
        liquidityNet = uint128(bytes16(data));
    }
}
