// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolState} from "../types/poolState.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {PoolId} from "../types/poolId.sol";
import {Locker} from "../types/locker.sol";

/// @title Extension Interface
/// @notice Interface for pool extensions that can hook into core operations
/// @dev Extensions must register with the core contract and implement these hooks
interface IExtension {
    /// @notice Called before a pool is initialized
    /// @param caller Address that initiated the pool initialization
    /// @param key Pool key identifying the pool
    /// @param tick Initial tick for the pool
    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external;

    /// @notice Called after a pool is initialized
    /// @param caller Address that initiated the pool initialization
    /// @param key Pool key identifying the pool
    /// @param tick Initial tick for the pool
    /// @param sqrtRatio Initial sqrt price ratio for the pool
    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, SqrtRatio sqrtRatio) external;

    /// @notice Called before a position is updated
    /// @param locker The current holder of the lock performing the position update
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position that is being updated
    /// @param liquidityDelta The change in liquidity that is being requested for the position
    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external;

    /// @notice Called after a position is updated
    /// @param locker The current holder of the lock performing the position update
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position that was updated
    /// @param liquidityDelta Change in liquidity of the specified position key range
    /// @param delta0 Change in token0 balance of the pool
    /// @param delta1 Change in token1 balance of the pool
    function afterUpdatePosition(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        int128 liquidityDelta,
        int128 delta0,
        int128 delta1,
        PoolState stateAfter
    ) external;

    /// @notice Called before a swap is executed
    /// @param locker The current holder of the lock performing the swap
    /// @param poolKey Pool key identifying the pool
    /// @param params Swap parameters containing amount, isToken1, sqrtRatioLimit, and skipAhead
    function beforeSwap(Locker locker, PoolKey memory poolKey, SwapParameters params) external;

    /// @notice Called after a swap is executed
    /// @param locker The current holder of the lock performing the swap
    /// @param poolKey Pool key identifying the pool
    /// @param params Swap parameters containing amount, isToken1, sqrtRatioLimit, and skipAhead
    /// @param delta0 Change in token0 balance
    /// @param delta1 Change in token1 balance
    /// @param stateAfter The pool state after the swap
    function afterSwap(
        Locker locker,
        PoolKey memory poolKey,
        SwapParameters params,
        int128 delta0,
        int128 delta1,
        PoolState stateAfter
    ) external;

    /// @notice Called before fees are collected from a position
    /// @param locker The current holder of the lock collecting fees
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position for which fees will be collected
    function beforeCollectFees(Locker locker, PoolKey memory poolKey, PositionId positionId) external;

    /// @notice Called after fees are collected from a position
    /// @param locker The current holder of the lock collecting fees
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position for which fees were collected
    /// @param amount0 Amount of token0 fees collected
    /// @param amount1 Amount of token1 fees collected
    function afterCollectFees(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        uint128 amount0,
        uint128 amount1
    ) external;
}

/// @title Core Interface
/// @notice Main interface for the Ekubo Protocol core contract
/// @dev Inherits from IFlashAccountant and IExposedStorage for additional functionality
interface ICore is IFlashAccountant, IExposedStorage {
    /// @notice Emitted when an extension is registered
    /// @param extension Address of the registered extension
    event ExtensionRegistered(address extension);

    /// @notice Emitted when a pool is initialized
    /// @param poolId Unique identifier for the pool
    /// @param poolKey Pool key containing token addresses and configuration
    /// @param tick Initial tick for the pool
    /// @param sqrtRatio Initial sqrt price ratio for the pool
    event PoolInitialized(PoolId poolId, PoolKey poolKey, int32 tick, SqrtRatio sqrtRatio);

    /// @notice Emitted when a position is updated
    /// @param locker The locker that is updating the position
    /// @param poolId Unique identifier for the pool
    /// @param positionId Identifier of the position specifying a salt and the bounds
    /// @param liquidityDelta The change in liquidity for the specified pool and position keys
    /// @param delta0 Change in token0 balance
    /// @param delta1 Change in token1 balance
    event PositionUpdated(
        address locker,
        PoolId poolId,
        PositionId positionId,
        int128 liquidityDelta,
        int128 delta0,
        int128 delta1,
        PoolState stateAfter
    );

    /// @notice Emitted when fees are collected from a position
    /// @param locker The locker that is collecting fees
    /// @param poolId Unique identifier for the pool
    /// @param positionId Identifier of the position specifying a salt and the bounds
    /// @param amount0 Amount of token0 fees collected
    /// @param amount1 Amount of token1 fees collected
    event PositionFeesCollected(address locker, PoolId poolId, PositionId positionId, uint128 amount0, uint128 amount1);

    /// @notice Emitted when fees are accumulated to a pool
    /// @param poolId Unique identifier for the pool
    /// @param amount0 Amount of token0 fees accumulated
    /// @param amount1 Amount of token1 fees accumulated
    /// @dev Note locker is ommitted because it's always the extension of the pool associated with poolId
    event FeesAccumulated(PoolId poolId, uint128 amount0, uint128 amount1);

    /// @notice Thrown when extension registration fails due to invalid call points
    error FailedRegisterInvalidCallPoints();

    /// @notice Thrown when trying to register an already registered extension
    error ExtensionAlreadyRegistered();

    /// @notice Thrown when saved balance operations would cause overflow
    error SavedBalanceOverflow();

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to use an unregistered extension
    error ExtensionNotRegistered();

    /// @notice Thrown when trying to operate on an uninitialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to withdraw all liquidity without collecting fees first
    error MustCollectFeesBeforeWithdrawingAllLiquidity();

    /// @notice When withdrawing all liquidity, extraData must be empty
    error ExtraDataMustBeEmpty();

    /// @notice Thrown when sqrt ratio limit is out of valid range
    error SqrtRatioLimitOutOfRange();

    /// @notice Thrown when sqrt ratio limit parameter given to swap is not a valid sqrt ratio
    error InvalidSqrtRatioLimit();

    /// @notice Thrown when the sqrt ratio limit is in the wrong direction of the current price
    error SqrtRatioLimitWrongDirection();

    /// @notice Thrown when saved balance tokens are not properly sorted
    error SavedBalanceTokensNotSorted();

    /// @notice Thrown when a position update would cause liquidityNet on a tick to exceed the maximum allowed
    /// @param tick The tick that would exceed the limit
    /// @param liquidityNet The resulting liquidityNet that exceeds the limit
    /// @param maxLiquidityPerTick The maximum allowed liquidity per tick
    error MaxLiquidityPerTickExceeded(int32 tick, uint128 liquidityNet, uint128 maxLiquidityPerTick);

    /// @notice Registers an extension with the core contract
    /// @dev Extensions must call this function to become registered. The call points are validated against the caller address
    /// @param expectedCallPoints Call points configuration for the extension
    function registerExtension(CallPoints memory expectedCallPoints) external;

    /// @notice Initializes a new pool with the given tick
    /// @dev Sets the initial price for a new pool in terms of tick
    /// @param poolKey Pool key identifying the pool to initialize
    /// @param tick Initial tick for the pool
    /// @return sqrtRatio Initial sqrt price ratio for the pool
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (SqrtRatio sqrtRatio);

    /// @notice Finds the previous initialized tick
    /// @param poolId Unique identifier for the pool
    /// @param fromTick Starting tick to search from
    /// @param tickSpacing Tick spacing for the pool
    /// @param skipAhead Number of ticks to skip for gas optimization
    /// @return tick The previous initialized tick
    /// @return isInitialized Whether the tick is initialized
    function prevInitializedTick(PoolId poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    /// @notice Finds the next initialized tick
    /// @param poolId Unique identifier for the pool
    /// @param fromTick Starting tick to search from
    /// @param tickSpacing Tick spacing for the pool
    /// @param skipAhead Number of ticks to skip for gas optimization
    /// @return tick The next initialized tick
    /// @return isInitialized Whether the tick is initialized
    function nextInitializedTick(PoolId poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    /// @notice Updates saved balances for later use
    /// @dev The saved balances are stored in a single slot. The resulting saved balance must fit within a uint128 container
    /// @param token0 Address of the first token (must be < token1)
    /// @param token1 Address of the second token (must be > token0)
    /// @param salt Unique identifier for the saved balance
    /// @param delta0 Change in token0 balance (positive for saving, negative for loading)
    /// @param delta1 Change in token1 balance (positive for saving, negative for loading)
    function updateSavedBalances(address token0, address token1, bytes32 salt, int256 delta0, int256 delta1)
        external
        payable;

    /// @notice Returns the accumulated fees per liquidity inside the given bounds
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower bound of the price range to get the snapshot
    /// @param tickLower Upper bound of the price range to get the snapshot
    /// @return feesPerLiquidity Accumulated fees per liquidity inside the bounds
    function getPoolFeesPerLiquidityInside(PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (FeesPerLiquidity memory feesPerLiquidity);

    /// @notice Accumulates tokens as fees for a pool
    /// @dev Only callable by the extension of the specified pool key. The current locker must be the extension.
    /// The extension must call this function within a lock callback
    /// @param poolKey Pool key identifying the pool
    /// @param amount0 Amount of token0 to accumulate as fees
    /// @param amount1 Amount of token1 to accumulate as fees
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external payable;

    /// @notice Updates a liquidity position and sets extra data
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position to update
    /// @param liquidityDelta The change in liquidity
    /// @param extraData The extra data to set (must be zero if the liquidity after update is zero)
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    function updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta, bytes16 extraData)
        external
        payable
        returns (int128 delta0, int128 delta1);

    /// @notice Collects accumulated fees from a position
    /// @param poolKey Pool key identifying the pool
    /// @param positionId The key of the position for which to collect fees
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(PoolKey memory poolKey, PositionId positionId)
        external
        returns (uint128 amount0, uint128 amount1);

    /// @notice Executes a swap against a pool
    /// @dev Function name is mined to have a zero function selector for gas efficiency
    /// @param poolKey Pool key identifying the pool
    /// @param params Swap parameters containing amount, isToken1, sqrtRatioLimit, and skipAhead
    /// @return delta0 Change in token0 balance of the pool
    /// @return delta1 Change in token1 balance of the pool
    /// @return stateAfter The pool state after the swap
    function swap_1773245541(PoolKey memory poolKey, SwapParameters params)
        external
        payable
        returns (int128 delta0, int128 delta1, PoolState stateAfter);
}
