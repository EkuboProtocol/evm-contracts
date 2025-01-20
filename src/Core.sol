// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "./types/keys.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "./types/feesPerLiquidity.sol";
import {isPriceIncreasing, SwapResult, swapResult} from "./math/swap.sol";
import {Position} from "./types/position.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {tickToSqrtRatio, sqrtRatioToTick, MAX_SQRT_RATIO, MIN_SQRT_RATIO} from "./math/ticks.sol";
import {Bitmap} from "./math/bitmap.sol";
import {
    shouldCallBeforeInitializePool,
    shouldCallAfterInitializePool,
    shouldCallBeforeUpdatePosition,
    shouldCallAfterUpdatePosition,
    shouldCallBeforeSwap,
    shouldCallAfterSwap,
    shouldCallBeforeCollectFees,
    shouldCallAfterCollectFees
} from "./types/callPoints.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {liquidityDeltaToAmountDelta, addLiquidityDelta} from "./math/liquidity.sol";
import {computeFee} from "./math/fee.sol";
import {findNextInitializedTick, findPrevInitializedTick, flipTick} from "./math/tickBitmap.sol";
import {
    ICore,
    UpdatePositionParameters,
    SwapParameters,
    IExtension,
    IForwardee,
    ILocker,
    NATIVE_TOKEN_ADDRESS
} from "./interfaces/ICore.sol";

contract Core is ICore, Ownable, ExposedStorage {
    using {findNextInitializedTick, findPrevInitializedTick, flipTick} for mapping(uint256 word => Bitmap bitmap);

    // We pack the delta and net.
    struct TickInfo {
        int128 liquidityDelta;
        uint128 liquidityNet;
    }

    // The pool price, we pack the tick with the sqrt ratio
    struct PoolPrice {
        uint192 sqrtRatio;
        int32 tick;
    }

    mapping(address extension => bool isRegistered) private isExtensionRegistered;
    mapping(address token => uint256 amountCollected) private protocolFeesCollected;

    // Keyed by the pool ID, which is the hash of the ABI-encoded pool key
    mapping(bytes32 poolId => PoolPrice price) private poolPrice;
    mapping(bytes32 poolId => uint128 liquidity) private poolLiquidity;
    mapping(bytes32 poolId => FeesPerLiquidity feesPerLiquidity) private poolFeesPerLiquidity;
    mapping(bytes32 poolId => mapping(bytes32 positionId => Position position)) private poolPositions;
    mapping(bytes32 poolId => mapping(int32 tick => TickInfo tickInfo)) private poolTicks;
    mapping(bytes32 poolId => mapping(int32 tick => FeesPerLiquidity feesPerLiquidityOutside)) private
        poolTickFeesPerLiquidityOutside;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) private poolInitializedTickBitmaps;

    // Balances saved for later
    mapping(address owner => mapping(address token => mapping(bytes32 salt => uint256))) private savedBalances;

    // The time after which the contract will no longer allow swaps or position updates with non-negative liquidity delta
    uint256 public immutable expirationTime;

    constructor(address owner, uint256 _expirationTime) {
        _initializeOwner(owner);
        expirationTime = _expirationTime;
    }

    function withdrawProtocolFees(address recipient, address token, uint256 amount) external onlyOwner {
        protocolFeesCollected[token] -= amount;
        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
        emit ProtocolFeesWithdrawn(recipient, token, amount);
    }

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) revert FailedRegisterInvalidCallPoints();
        if (!isExtensionRegistered[msg.sender]) {
            isExtensionRegistered[msg.sender] = true;
            emit ExtensionRegistered(msg.sender);
        }
    }

    function requireLocker() private view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(0), 1)
            locker := tload(add(0x100000000, id))
        }
        if (locker != msg.sender) revert LockerOnly();
    }

    // Negative means erasing debt, positive means adding debt
    function accountDebt(uint256 id, address token, int256 debtChange) private {
        if (debtChange == 0) return;

        bytes32 slot;
        int256 current;
        assembly ("memory-safe") {
            slot := add(add(id, 0x300000000), token)
            current := tload(slot)
        }

        // this is a checked addition, so it will revert if it overflows
        int256 next = current + debtChange;

        if (current == 0 && next != 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(id, 0x200000000)

                tstore(nzdCountSlot, add(tload(nzdCountSlot), 1))
            }
        } else if (current != 0 && next == 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(id, 0x200000000)

                tstore(nzdCountSlot, sub(tload(nzdCountSlot), 1))
            }
        }

        assembly ("memory-safe") {
            tstore(slot, next)
        }
    }

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(0)
            // store the count
            tstore(0, add(id, 1))
            // store the address of the locker
            tstore(add(0x100000000, id), caller())
        }

        // We make the assumption that this code can never be called recursively this many times, causing storage slots to overlap
        // This is just the codified assumption
        assert(id < type(uint32).max);

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDebtCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(0, id)
            // remove the address
            tstore(add(0x100000000, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDebtCount := tload(add(0x200000000, id))
        }

        if (nonzeroDebtCount != 0) revert DebtsNotZeroed();
    }

    function forward(address to, bytes calldata data) external returns (bytes memory result) {
        (uint256 id, address locker) = requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(add(0x100000000, id), to)
        }

        result = IForwardee(to).forwarded(locker, id, data);

        assembly ("memory-safe") {
            tstore(add(0x100000000, id), locker)
        }
    }

    function initializePool(PoolKey memory poolKey, int32 tick) external returns (uint256 sqrtRatio) {
        poolKey.validatePoolKey();

        if (poolKey.extension != address(0)) {
            if (!isExtensionRegistered[poolKey.extension]) {
                revert ExtensionNotRegistered();
            }

            if (shouldCallBeforeInitializePool(poolKey.extension) && poolKey.extension != msg.sender) {
                IExtension(poolKey.extension).beforeInitializePool(msg.sender, poolKey, tick);
            }
        }

        bytes32 poolId = poolKey.toPoolId();
        PoolPrice memory price = poolPrice[poolId];
        if (price.sqrtRatio != 0) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        poolPrice[poolId] = PoolPrice({sqrtRatio: uint192(sqrtRatio), tick: tick});

        emit PoolInitialized(poolKey, tick, sqrtRatio);

        if (shouldCallAfterInitializePool(poolKey.extension) && poolKey.extension != msg.sender) {
            IExtension(poolKey.extension).afterInitializePool(msg.sender, poolKey, tick, sqrtRatio);
        }
    }

    function prevInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            poolInitializedTickBitmaps[poolId].findPrevInitializedTick(fromTick, tickSpacing, skipAhead);
    }

    function nextInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            poolInitializedTickBitmaps[poolId].findNextInitializedTick(fromTick, tickSpacing, skipAhead);
    }

    uint256 constant MAX_INT256 = type(uint256).max >> 1; // == (1<<255) - 1

    // Token must not be the NATIVE_TOKEN_ADDRESS.
    // If you want to pay in the native token, simply transfer it to this contract.
    function pay(address token, bytes memory data) external returns (uint256 payment) {
        (uint256 id, address caller) = requireLocker();

        uint256 tokenBalanceBefore = SafeTransferLib.balanceOf(token, address(this));

        ILocker(caller).payCallback(id, token, data);

        uint256 tokenBalanceAfter = SafeTransferLib.balanceOf(token, address(this));

        if (tokenBalanceAfter <= tokenBalanceBefore) {
            revert NoPaymentMade();
        }

        unchecked {
            payment = tokenBalanceAfter - tokenBalanceBefore;

            if (payment > MAX_INT256) revert PaymentTooLarge();

            // The unary negative operator never fails because payment is less than max int256
            accountDebt(id, token, -int256(payment));
        }
    }

    function load(address token, bytes32 salt, uint128 amount) external {
        (uint256 id, address owner) = requireLocker();

        accountDebt(id, token, -int256(uint256(amount)));

        savedBalances[owner][token][salt] -= amount;

        emit LoadedBalance(owner, token, salt, amount);
    }

    function withdraw(address token, address recipient, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDebt(id, token, int256(uint256(amount)));

        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }

    function save(address owner, address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDebt(id, token, int256(uint256(amount)));

        savedBalances[owner][token][salt] += amount;

        emit SavedBalance(owner, token, salt, amount);
    }

    // Returns the pool fees per liquidity inside the given bounds.
    function getPoolFeesPerLiquidityInside(bytes32 poolId, Bounds memory bounds)
        public
        view
        returns (FeesPerLiquidity memory)
    {
        int32 tick = poolPrice[poolId].tick;
        mapping(int32 => FeesPerLiquidity) storage poolIdEntry = poolTickFeesPerLiquidityOutside[poolId];
        FeesPerLiquidity memory lower = poolIdEntry[bounds.lower];
        FeesPerLiquidity memory upper = poolIdEntry[bounds.upper];

        if (tick < bounds.lower) {
            return lower.sub(upper);
        } else if (tick < bounds.upper) {
            FeesPerLiquidity memory fees = poolFeesPerLiquidity[poolId];

            return fees.sub(lower).sub(upper);
        } else {
            return upper.sub(lower);
        }
    }

    // Accumulates tokens to fees of a pool. Only callable by the extension of the specified pool
    // key, i.e. the current locker _must_ be the extension.
    // The extension must call this function within a lock callback.
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external {
        (uint256 id, address locker) = requireLocker();
        require(locker == poolKey.extension);
        bytes32 poolId = poolKey.toPoolId();
        uint128 liquidity = poolLiquidity[poolId];
        require(liquidity != 0);

        poolFeesPerLiquidity[poolKey.toPoolId()] =
            poolFeesPerLiquidity[poolId].add(feesPerLiquidityFromAmounts(amount0, amount1, liquidity));

        accountDebt(id, poolKey.token0, int256(uint256(amount0)));
        accountDebt(id, poolKey.token1, int256(uint256(amount1)));

        emit FeesAccumulated(poolKey, amount0, amount1);
    }

    function updateTick(bytes32 poolId, int32 tick, uint32 tickSpacing, int128 liquidityDelta, bool isUpper) private {
        TickInfo storage tickInfo = poolTicks[poolId][tick];

        uint128 liquidityNetNext = addLiquidityDelta(tickInfo.liquidityNet, liquidityDelta);
        // this is checked math
        int128 liquidityDeltaNext =
            isUpper ? tickInfo.liquidityDelta - liquidityDelta : tickInfo.liquidityDelta + liquidityDelta;

        if ((tickInfo.liquidityNet == 0) != (liquidityNetNext == 0)) {
            flipTick(poolInitializedTickBitmaps[poolId], tick, tickSpacing);
        }

        tickInfo.liquidityDelta = liquidityDeltaNext;
        tickInfo.liquidityNet = liquidityNetNext;
    }

    function updatePosition(PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        returns (int128 delta0, int128 delta1)
    {
        if (block.timestamp > expirationTime && params.liquidityDelta > 0) revert ContractHasExpired();

        (uint256 id, address locker) = requireLocker();

        if (shouldCallBeforeUpdatePosition(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).beforeUpdatePosition(locker, poolKey, params);
        }

        if (params.liquidityDelta != 0) {
            params.bounds.validateBounds(poolKey.tickSpacing);

            bytes32 poolId = poolKey.toPoolId();
            PoolPrice memory price = poolPrice[poolId];
            if (price.sqrtRatio == 0) revert PoolNotInitialized();

            (uint256 sqrtRatioLower, uint256 sqrtRatioUpper) =
                (tickToSqrtRatio(params.bounds.lower), tickToSqrtRatio(params.bounds.upper));

            (delta0, delta1) =
                liquidityDeltaToAmountDelta(price.sqrtRatio, params.liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

            PositionKey memory positionKey = PositionKey({salt: params.salt, owner: locker, bounds: params.bounds});

            if (params.liquidityDelta < 0) {
                if (poolKey.fee != 0) {
                    uint128 amount0Fee = computeFee(uint128(-delta0), poolKey.fee);
                    uint128 amount1Fee = computeFee(uint128(-delta1), poolKey.fee);
                    // this will never overflow for a reasonably behaved token
                    unchecked {
                        if (amount0Fee > 0) {
                            protocolFeesCollected[poolKey.token0] += amount0Fee;
                        }
                        if (amount1Fee > 0) {
                            protocolFeesCollected[poolKey.token1] += amount1Fee;
                        }
                    }
                    delta0 += int128(amount0Fee);
                    delta1 += int128(amount1Fee);
                    emit ProtocolFeesPaid(poolKey, positionKey, amount0Fee, amount1Fee);
                }
            }

            bytes32 positionId = positionKey.toPositionId();
            Position memory position = poolPositions[poolId][positionId];

            FeesPerLiquidity memory feesPerLiquidityInside = getPoolFeesPerLiquidityInside(poolId, params.bounds);

            (uint128 fees0, uint128 fees1) = position.fees(feesPerLiquidityInside);

            uint128 liquidityNext = addLiquidityDelta(position.liquidity, params.liquidityDelta);

            if (liquidityNext != 0) {
                position.feesPerLiquidityInsideLast =
                    feesPerLiquidityInside.sub(feesPerLiquidityFromAmounts(fees0, fees1, liquidityNext));
                position.liquidity = liquidityNext;
                poolPositions[poolId][positionId] = position;
            } else {
                if (fees0 != 0 || fees1 != 0) revert MustCollectFeesBeforeWithdrawingAllLiquidity();
                poolPositions[poolId][positionId] =
                    Position({liquidity: 0, feesPerLiquidityInsideLast: FeesPerLiquidity(0, 0)});
            }

            updateTick(poolId, params.bounds.lower, poolKey.tickSpacing, params.liquidityDelta, false);
            updateTick(poolId, params.bounds.upper, poolKey.tickSpacing, params.liquidityDelta, true);

            if (price.tick >= params.bounds.lower && price.tick < params.bounds.upper) {
                poolLiquidity[poolId] = addLiquidityDelta(poolLiquidity[poolId], params.liquidityDelta);
            }

            accountDebt(id, poolKey.token0, delta0);
            accountDebt(id, poolKey.token1, delta1);

            emit PositionUpdated(locker, poolKey, params, delta0, delta1);
        }

        if (shouldCallAfterUpdatePosition(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterUpdatePosition(locker, poolKey, params, delta0, delta1);
        }
    }

    function collectFees(PoolKey memory poolKey, bytes32 salt, Bounds memory bounds)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (uint256 id, address locker) = requireLocker();

        if (shouldCallBeforeCollectFees(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).beforeCollectFees(locker, poolKey, salt, bounds);
        }

        bytes32 poolId = poolKey.toPoolId();
        PositionKey memory positionKey = PositionKey({salt: salt, owner: locker, bounds: bounds});
        bytes32 positionId = positionKey.toPositionId();
        Position memory position = poolPositions[poolId][positionId];

        FeesPerLiquidity memory feesPerLiquidityInside = getPoolFeesPerLiquidityInside(poolId, bounds);

        (amount0, amount1) = position.fees(feesPerLiquidityInside);

        poolPositions[poolId][positionId] =
            Position({liquidity: position.liquidity, feesPerLiquidityInsideLast: feesPerLiquidityInside});

        accountDebt(id, poolKey.token0, -int256(uint256(amount0)));
        accountDebt(id, poolKey.token1, -int256(uint256(amount1)));

        emit PositionFeesCollected(poolKey, positionKey, amount0, amount1);

        if (shouldCallAfterCollectFees(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterCollectFees(locker, poolKey, salt, bounds, amount0, amount1);
        }
    }

    function swap(PoolKey memory poolKey, SwapParameters memory params)
        external
        returns (int128 delta0, int128 delta1)
    {
        if (block.timestamp > expirationTime) {
            revert ContractHasExpired();
        }

        (uint256 id, address locker) = requireLocker();

        if (shouldCallBeforeSwap(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).beforeSwap(locker, poolKey, params);
        }

        bytes32 poolId = poolKey.toPoolId();
        uint256 sqrtRatio;
        int32 tick;
        {
            PoolPrice storage price = poolPrice[poolId];
            (tick, sqrtRatio) = (price.tick, price.sqrtRatio);
        }

        if (sqrtRatio == 0) revert PoolNotInitialized();

        // 0 swap amount is no-op
        if (params.amount != 0) {
            bool increasing = isPriceIncreasing(params.amount, params.isToken1);
            if (increasing) {
                if (params.sqrtRatioLimit < sqrtRatio) revert SqrtRatioLimitWrongDirection();
                if (params.sqrtRatioLimit > MAX_SQRT_RATIO) revert SqrtRatioLimitOutOfRange();
            } else {
                if (params.sqrtRatioLimit > sqrtRatio) revert SqrtRatioLimitWrongDirection();
                if (params.sqrtRatioLimit < MIN_SQRT_RATIO) revert SqrtRatioLimitOutOfRange();
            }

            mapping(uint256 => Bitmap) storage initializedTickBitmaps = poolInitializedTickBitmaps[poolKey.toPoolId()];
            mapping(int32 => FeesPerLiquidity) storage tickFeesPerLiquidityOutside =
                poolTickFeesPerLiquidityOutside[poolId];
            mapping(int32 => TickInfo) storage ticks = poolTicks[poolId];

            int128 amountRemaining = params.amount;
            uint128 liquidity = poolLiquidity[poolId];

            uint128 calculatedAmount = 0;

            FeesPerLiquidity memory feesPerLiquidity = poolFeesPerLiquidity[poolId];

            while (amountRemaining != 0 && sqrtRatio != params.sqrtRatioLimit) {
                (int32 nextTick, bool isInitialized) = increasing
                    ? initializedTickBitmaps.findNextInitializedTick(tick, poolKey.tickSpacing, params.skipAhead)
                    : initializedTickBitmaps.findPrevInitializedTick(tick, poolKey.tickSpacing, params.skipAhead);

                uint256 nextTickSqrtRatio = tickToSqrtRatio(nextTick);
                uint256 limitedNextSqrtRatio = increasing
                    ? FixedPointMathLib.min(nextTickSqrtRatio, params.sqrtRatioLimit)
                    : FixedPointMathLib.max(nextTickSqrtRatio, params.sqrtRatioLimit);

                SwapResult memory result = swapResult(
                    sqrtRatio, liquidity, limitedNextSqrtRatio, amountRemaining, params.isToken1, poolKey.fee
                );

                if (result.feeAmount != 0) {
                    // we know liquidity is non zero if this happens
                    feesPerLiquidity = feesPerLiquidity.add(
                        increasing
                            ? feesPerLiquidityFromAmounts(0, result.feeAmount, liquidity)
                            : feesPerLiquidityFromAmounts(result.feeAmount, 0, liquidity)
                    );
                }

                amountRemaining -= result.consumedAmount;
                calculatedAmount += result.calculatedAmount;

                if (result.sqrtRatioNext == nextTickSqrtRatio) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = increasing ? nextTick : nextTick - 1;

                    if (isInitialized) {
                        int128 liquidityDelta = ticks[nextTick].liquidityDelta;
                        liquidity = increasing
                            ? addLiquidityDelta(liquidity, liquidityDelta)
                            : addLiquidityDelta(liquidity, -liquidityDelta);
                        tickFeesPerLiquidityOutside[nextTick] =
                            feesPerLiquidity.sub(tickFeesPerLiquidityOutside[nextTick]);
                    }
                } else if (sqrtRatio != result.sqrtRatioNext) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = sqrtRatioToTick(sqrtRatio);
                }
            }

            if (params.isToken1) {
                // todo: overflow checks?
                delta0 = (params.amount < 0) ? int128(calculatedAmount) : -int128(calculatedAmount);
                delta1 = params.amount - amountRemaining;
            } else {
                delta0 = params.amount - amountRemaining;
                delta1 = (params.amount < 0) ? int128(calculatedAmount) : -int128(calculatedAmount);
            }

            poolPrice[poolId] = PoolPrice({sqrtRatio: uint192(sqrtRatio), tick: tick});
            poolLiquidity[poolId] = liquidity;
            poolFeesPerLiquidity[poolId] = feesPerLiquidity;

            accountDebt(id, poolKey.token0, delta0);
            accountDebt(id, poolKey.token1, delta1);

            emit Swapped(locker, poolKey, params, delta0, delta1, sqrtRatio, tick, liquidity);
        }

        if (shouldCallAfterSwap(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterSwap(locker, poolKey, params, delta0, delta1);
        }
    }

    // Used to pay native tokens owed
    receive() external payable {
        (uint256 id,) = requireLocker();

        // Assumption that msg.value will never overflow this cast or subtraction
        unchecked {
            accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
        }
    }
}
