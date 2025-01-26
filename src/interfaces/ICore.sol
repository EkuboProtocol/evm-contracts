// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";

struct UpdatePositionParameters {
    bytes32 salt;
    Bounds bounds;
    int128 liquidityDelta;
}

struct SwapParameters {
    int128 amount;
    bool isToken1;
    uint256 sqrtRatioLimit;
    uint256 skipAhead;
}

interface IExtension {
    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external;
    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, uint256 sqrtRatio) external;

    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external;
    function afterUpdatePosition(
        address locker,
        PoolKey memory poolKey,
        UpdatePositionParameters memory params,
        int128 delta0,
        int128 delta1
    ) external;

    function beforeSwap(address locker, PoolKey memory poolKey, SwapParameters memory params) external;
    function afterSwap(
        address locker,
        PoolKey memory poolKey,
        SwapParameters memory params,
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
    event PoolInitialized(PoolKey poolKey, int32 tick, uint256 sqrtRatio);
    event LoadedBalance(address owner, address token, bytes32 salt, uint128 amount);
    event SavedBalance(address owner, address token, bytes32 salt, uint128 amount);
    event PositionFeesCollected(PoolKey poolKey, PositionKey positionKey, uint128 amount0, uint128 amount1);
    event Swapped(
        address locker,
        PoolKey poolKey,
        SwapParameters params,
        int128 delta0,
        int128 delta1,
        uint256 sqrtRatioAfter,
        int32 tickAfter,
        uint128 liquidityAfter
    );
    event FeesAccumulated(PoolKey poolKey, uint128 amount0, uint128 amount1);
    event PositionUpdated(
        address locker, PoolKey poolKey, UpdatePositionParameters params, int128 delta0, int128 delta1
    );
    event ProtocolFeesPaid(PoolKey poolKey, PositionKey positionKey, uint128 amount0, uint128 amount1);

    // This error is thrown by swaps and deposits when this particular deployment of the contract is expired.
    error FailedRegisterInvalidCallPoints();
    error InsufficientSavedBalance();
    error PoolAlreadyInitialized();
    error ExtensionNotRegistered();
    error PoolNotInitialized();
    error MustCollectFeesBeforeWithdrawingAllLiquidity();
    error SqrtRatioLimitWrongDirection();
    error SqrtRatioLimitOutOfRange();

    // Allows the owner of the contract to withdraw the protocol withdrawal fees collected
    // To withdraw the native token protocol fees, call with token = NATIVE_TOKEN_ADDRESS
    function withdrawProtocolFees(address recipient, address token, uint256 amount) external;

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external;

    // Sets the initial price for a new pool in terms of tick.
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (uint256 sqrtRatio);

    function prevInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    function nextInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    // Loads from the saved balance of the contract to pay in the current lock context.
    function load(address token, bytes32 salt, uint128 amount) external;

    // Saves an amount of a token to be used later.
    function save(address owner, address token, bytes32 salt, uint128 amount) external;

    // Returns the pool fees per liquidity inside the given bounds.
    function getPoolFeesPerLiquidityInside(bytes32 poolId, Bounds memory bounds)
        external
        view
        returns (FeesPerLiquidity memory);

    // Accumulates tokens to fees of a pool. Only callable by the extension of the specified pool
    // key, i.e. the current locker _must_ be the extension.
    // The extension must call this function within a lock callback.
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external;

    function updatePosition(PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        returns (int128 delta0, int128 delta1);

    function collectFees(PoolKey memory poolKey, bytes32 salt, Bounds memory bounds)
        external
        returns (uint128 amount0, uint128 amount1);

    function swap(PoolKey memory poolKey, SwapParameters memory params)
        external
        returns (int128 delta0, int128 delta1);
}
