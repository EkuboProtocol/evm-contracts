// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ICore} from "../interfaces/ICore.sol";
import {CoreStorageLayout} from "./CoreStorageLayout.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title Core Library
/// @notice Library providing common storage getters for external contracts
/// @dev These functions access Core contract storage directly for gas efficiency
library CoreLib {
    using ExposedStorageLib for *;

    /// @notice Checks if an extension is registered with the core contract
    /// @param core The core contract instance
    /// @param extension The extension address to check
    /// @return registered True if the extension is registered
    function isExtensionRegistered(ICore core, address extension) internal view returns (bool registered) {
        registered = uint256(core.sload(CoreStorageLayout.isExtensionRegisteredSlot(extension))) != 0;
    }

    /// @notice Gets the current state of a pool
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @return state The current state of the pool
    function poolState(ICore core, PoolId poolId) internal view returns (PoolState state) {
        state = PoolState.wrap(core.sload(CoreStorageLayout.poolStateSlot(poolId)));
    }

    /// @notice Gets the current global fees per liquidity for a pool
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @return feesPerLiquidity The current global fees per liquidtiy of the pool
    function getPoolFeesPerLiquidity(ICore core, PoolId poolId)
        internal
        view
        returns (FeesPerLiquidity memory feesPerLiquidity)
    {
        StorageSlot fplFirstSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        (bytes32 value0, bytes32 value1) = core.sload(fplFirstSlot, fplFirstSlot.next());

        feesPerLiquidity.value0 = uint256(value0);
        feesPerLiquidity.value1 = uint256(value1);
    }

    /// @notice Gets position data for a specific position in a pool
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @param positionId The unique identifier for the position
    /// @return position The position data including liquidity, extraData, and fees
    function poolPositions(ICore core, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (Position memory position)
    {
        StorageSlot firstSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        (bytes32 v0, bytes32 v1, bytes32 v2) = core.sload(firstSlot, firstSlot.add(1), firstSlot.add(2));

        assembly ("memory-safe") {
            mstore(position, shl(128, v0))
            mstore(add(position, 0x20), shr(128, v0))
        }

        position.feesPerLiquidityInsideLast = FeesPerLiquidity(uint256(v1), uint256(v2));
    }

    /// @notice Gets saved balances for a specific owner and token pair
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
        uint256 value = uint256(core.sload(CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt)));

        savedBalance0 = uint128(value >> 128);
        savedBalance1 = uint128(value);
    }

    /// @notice Gets tick information for a specific tick in a pool
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @param tick The tick to query
    /// @return liquidityDelta The liquidity change when crossing this tick
    /// @return liquidityNet The net liquidity above this tick
    function poolTicks(ICore core, PoolId poolId, int32 tick)
        internal
        view
        returns (int128 liquidityDelta, uint128 liquidityNet)
    {
        bytes32 data = core.sload(CoreStorageLayout.poolTicksSlot(poolId, tick));

        // takes only least significant 128 bits
        liquidityDelta = int128(uint128(uint256(data)));
        // takes only most significant 128 bits
        liquidityNet = uint128(bytes16(data));
    }

    /// @notice Executes a swap against the core contract using assembly optimization
    /// @dev Uses assembly to make direct call to core contract for gas efficiency
    /// @param core The core contract instance
    /// @param value Native token value to send with the swap
    /// @param poolKey Pool key identifying the pool
    /// @param params The swap parameters to use
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    /// @return stateAfter The pool state after the swap
    function swap(ICore core, uint256 value, PoolKey memory poolKey, SwapParameters params)
        internal
        returns (int128 delta0, int128 delta1, PoolState stateAfter)
    {
        assembly ("memory-safe") {
            let free := mload(0x40)

            // the function selector of swap is 0
            mstore(free, 0)

            // Copy PoolKey
            mcopy(add(free, 4), poolKey, 96)

            // Add SwapParameters
            mstore(add(free, 100), params)

            if iszero(call(gas(), core, value, free, 132, free, 96)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            // Extract return values
            delta0 := mload(free)
            delta1 := mload(add(free, 32))
            stateAfter := mload(add(free, 64))
        }
    }
}
