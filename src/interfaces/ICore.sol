// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {IExposedStorage} from "../base/ExposedStorage.sol";

interface ILocker {
    function locked(uint256 id, bytes calldata data) external returns (bytes memory);
    function payCallback(uint256 id, address token, bytes calldata data) external returns (bytes memory);
}

interface IForwardee {
    function forwarded(address locker, uint256 id, bytes calldata data) external returns (bytes memory);
}

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

// This address should never be used by any other chain but also has lots of zeroes so it still works well with calldata compression
// We also know this address will always be token0
address constant NATIVE_TOKEN_ADDRESS = address(0x0000000000000000000000000000eeEEee000000);

interface ICore is IExposedStorage {
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

    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();
    error LockerOnly();
    error DeltasNotZeroed(uint256 count);
    error PoolAlreadyInitialized();
    error ExtensionNotRegistered(address extension);
    error OnlyCallableByExtension();
    error CannotAccumulateFeesWithZeroLiquidity();
    error LiquidityUnderflow();
    error LiquidityOverflow();
    error PoolNotInitialized();
    error MustCollectFeesBeforeWithdrawingAllLiquidity();
    error SqrtRatioLimitWrongDirection();
    error SqrtRatioLimitOutOfRange();
    error PaymentTooLarge();
    error NoPaymentMade();

    // Allows the owner of the contract to withdraw the protocol withdrawal fees collected
    function withdrawProtocolFees(address recipient, address token, uint256 amount) external;

    // Allows the owner of the contract to withdraw the native token protocol withdrawal fees collected
    function withdrawNativeProtocolFees(address recipient, uint256 amount) external;

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external;

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external returns (bytes memory result);

    // Allows the holder of a lock to forward the context to another address, where the forwardee can perform any actions
    // and the original locker must pay for it.
    function forward(address to, bytes calldata data) external returns (bytes memory result);

    // Sets the initial price for a new pool in terms of tick.
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (uint256 sqrtRatio);

    function prevInitializedTick(PoolKey memory poolKey, int32 fromTick, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    function nextInitializedTick(PoolKey memory poolKey, int32 fromTick, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized);

    // Token must not be the NATIVE_TOKEN_ADDRESS.
    // If you want to pay in the chain's native token, simply transfer it to this contract using a call.
    // The payer must implement payCallback in which they must transfer the token to Core.
    function pay(address token, bytes memory data) external returns (uint256 payment);

    // Loads from the saved balance of the contract to pay in the current lock context.
    function load(address token, bytes32 salt, uint128 amount) external;

    // Withdraws a token amount from the core contract to the given recipient.
    function withdraw(address token, address recipient, uint128 amount) external;
    // Withdraws an amount of the native token
    function withdrawNative(address recipient, uint128 amount) external;

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

    // Used to pay native tokens owed
    receive() external payable;
}
