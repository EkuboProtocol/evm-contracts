// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SavedBalanceKey} from "../types/savedBalanceKey.sol";
import {PositionKey, Bounds} from "../types/positionKey.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

struct UpdatePositionParameters {
    bytes32 salt;
    Bounds bounds;
    int128 liquidityDelta;
}

interface IExtension {
    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external;
    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, SqrtRatio sqrtRatio) external;

    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external;
    function afterUpdatePosition(
        address locker,
        PoolKey memory poolKey,
        UpdatePositionParameters memory params,
        int128 delta0,
        int128 delta1
    ) external;

    function beforeSwap(
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external;
    function afterSwap(
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int128 delta0,
        int128 delta1
    ) external;

    function beforeCollectFees(address locker, PoolKey memory poolKey, bytes32 salt, Bounds memory bounds) external;
    function afterCollectFees(
        address locker,
        PoolKey memory poolKey,
        bytes32 salt,
        Bounds memory bounds,
        uint128 amount0,
        uint128 amount1
    ) external;
}

interface ICore is IFlashAccountant, IExposedStorage {
    event ProtocolFeesWithdrawn(address recipient, address token, uint256 amount);
    event ExtensionRegistered(address extension);
    event PoolInitialized(bytes16 poolId, PoolKey poolKey, int32 tick, SqrtRatio sqrtRatio);
    event PositionFeesCollected(bytes16 poolId, PositionKey positionKey, uint128 amount0, uint128 amount1);
    event FeesAccumulated(bytes16 poolId, uint128 amount0, uint128 amount1);
    event PositionUpdated(
        address locker, bytes16 poolId, UpdatePositionParameters params, int128 delta0, int128 delta1
    );

    // This error is thrown by swaps and deposits when this particular deployment of the contract is expired.
    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();
    error InsufficientSavedBalance();
    error PoolAlreadyInitialized();
    error ExtensionNotRegistered();
    error PoolNotInitialized();
    error MustCollectFeesBeforeWithdrawingAllLiquidity();
    error SqrtRatioLimitOutOfRange();
    error InvalidSqrtRatioLimit();
    error SavedBalanceTokensNotSorted();

    // Allows the owner of the contract to withdraw the protocol withdrawal fees collected
    // To withdraw the native token protocol fees, call with token = NATIVE_TOKEN_ADDRESS
    function withdrawProtocolFees(address recipient, address token, uint256 amount) external;

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external;

    // Sets the initial price for a new pool in terms of tick.
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (SqrtRatio sqrtRatio);

    function prevInitializedTick(bytes16 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    function nextInitializedTick(bytes16 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    // Saves an amount of 2 tokens to be used later, in a single slot.
    function updateSavedBalances(SavedBalanceKey memory key, int128 delta0, int128 delta1) external payable;

    // Returns the pool fees per liquidity inside the given bounds.
    function getPoolFeesPerLiquidityInside(PoolKey memory poolKey, Bounds memory bounds)
        external
        view
        returns (FeesPerLiquidity memory);

    // Accumulates tokens to fees of a pool. Only callable by the extension of the specified pool
    // key, i.e. the current locker _must_ be the extension.
    // The extension must call this function within a lock callback.
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external payable;

    function updatePosition(PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        payable
        returns (int128 delta0, int128 delta1);

    function collectFees(PoolKey memory poolKey, bytes32 salt, Bounds memory bounds)
        external
        returns (uint128 amount0, uint128 amount1);

    function swap_611415377(
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external payable returns (int128 delta0, int128 delta1);
}
