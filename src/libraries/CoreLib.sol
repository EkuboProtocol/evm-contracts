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

    /// @param core The core contract to call swap on
    /// @param poolKey Pool key identifying the pool
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param sqrtRatioLimit Price limit for the swap
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    function swap(
        ICore core,
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        assembly ("memory-safe") {
            // Allocate memory for calldata (108 bytes total)
            let data := mload(0x40)

            // Pack the data manually
            mstore(data, 0) // selector (4 bytes of zeros)
            mstore(add(data, 4), shl(96, mload(poolKey))) // token0 (20 bytes)
            mstore(add(data, 24), shl(96, mload(add(poolKey, 32)))) // token1 (20 bytes)
            mstore(add(data, 44), mload(add(poolKey, 64))) // config (32 bytes)

            // Pack the tail word (offset 76-107): amount(16) + isToken1(1) + sqrtRatioLimit(12) + skipAhead(3)
            let tailWord :=
                or(
                    shl(128, amount), // amount in high 16 bytes (128 bits)
                    or(
                        shl(120, isToken1), // isToken1 in next byte (120 bits from right)
                        or(
                            shl(24, sqrtRatioLimit), // sqrtRatioLimit in next 12 bytes (24 bits from right)
                            and(skipAhead, 0xFFFFFF) // skipAhead in low 3 bytes
                        )
                    )
                )
            mstore(add(data, 76), tailWord)

            if iszero(call(gas(), core, value, data, 108, data, 96)) {
                returndatacopy(data, 0, returndatasize())
                revert(data, returndatasize())
            }

            delta0 := signextend(15, mload(data))
            delta1 := signextend(15, mload(add(32, data)))
            stateAfter := mload(add(64, data))
        }
    }
}
