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
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../types/sqrtRatio.sol";
import {isPriceIncreasing} from "../math/isPriceIncreasing.sol";

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
        registered = uint256(core.sload(CoreStorageLayout.isExtensionRegisteredSlot(extension))) != 0;
    }

    /// @notice Gets the current state of a pool
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @return state The current state of the pool
    function poolState(ICore core, PoolId poolId) internal view returns (PoolState state) {
        state = PoolState.wrap(core.sload(CoreStorageLayout.poolStateSlot(poolId)));
    }

    /// @notice Gets position data for a specific position in a pool
    /// @dev Accesses the core contract's storage directly for gas efficiency
    /// @param core The core contract instance
    /// @param poolId The unique identifier for the pool
    /// @param positionId The unique identifier for the position
    /// @return position The position data including liquidity and fees
    function poolPositions(ICore core, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (Position memory position)
    {
        bytes32 firstSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        (bytes32 v0, bytes32 v1, bytes32 v2) =
            core.sload(firstSlot, bytes32(uint256(firstSlot) + 1), bytes32(uint256(firstSlot) + 2));

        position.liquidity = uint128(uint256(v0));
        position.feesPerLiquidityInsideLast = FeesPerLiquidity(uint256(v1), uint256(v2));
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
        uint256 value = uint256(core.sload(CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt)));

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

    /// @notice Executes a swap with all parameters specified
    /// @dev Calls the core contract's fallback function with custom encoding
    /// @param core The core contract instance
    /// @param poolKey Pool key identifying the pool
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param sqrtRatioLimit Price limit for the swap
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    /// @return stateAfter The pool state after the swap
    function swap(
        ICore core,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        bytes memory data = abi.encodePacked(
            bytes4(0x00000000), // dummy selector, ignored by fallback
            poolKey.token0, // 20 bytes
            poolKey.token1, // 20 bytes
            poolKey.config, // 32 bytes (contains extension, fee, tick spacing)
            amount, // 16 bytes (int128)
            isToken1, // 1 byte
            sqrtRatioLimit, // 12 bytes (uint96)
            skipAhead // 32 bytes
        );

        (bool success, bytes memory result) = address(core).call(data);
        if (!success) {
            // Re-throw the revert reason
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        assembly ("memory-safe") {
            delta0 := mload(add(result, 0x20))
            delta1 := mload(add(result, 0x40))
            stateAfter := mload(add(result, 0x60))
        }
    }

    /// @notice Executes a swap with automatic sqrtRatioLimit based on swap direction
    /// @dev sqrtRatioLimit is set to MIN_SQRT_RATIO or MAX_SQRT_RATIO based on price direction
    /// @param core The core contract instance
    /// @param poolKey Pool key identifying the pool
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    /// @return stateAfter The pool state after the swap
    function swap(ICore core, PoolKey memory poolKey, int128 amount, bool isToken1, uint256 skipAhead)
        internal
        returns (int128 delta0, int128 delta1, PoolState stateAfter)
    {
        bool increasing = isPriceIncreasing(amount, isToken1);
        SqrtRatio sqrtRatioLimit = increasing ? MAX_SQRT_RATIO : MIN_SQRT_RATIO;
        return swap(core, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
    }

    /// @notice Executes a swap with automatic sqrtRatioLimit and skipAhead = 0
    /// @dev sqrtRatioLimit is set to MIN_SQRT_RATIO or MAX_SQRT_RATIO based on price direction
    /// @param core The core contract instance
    /// @param poolKey Pool key identifying the pool
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    /// @return stateAfter The pool state after the swap
    function swap(ICore core, PoolKey memory poolKey, int128 amount, bool isToken1)
        internal
        returns (int128 delta0, int128 delta1, PoolState stateAfter)
    {
        return swap(core, poolKey, amount, isToken1, 0);
    }
}
