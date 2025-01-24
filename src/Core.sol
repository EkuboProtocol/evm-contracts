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
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {ExpiringContract} from "./base/ExpiringContract.sol";
import {liquidityDeltaToAmountDelta, addLiquidityDelta, subLiquidityDelta} from "./math/liquidity.sol";
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

contract Core is ICore, ExpiringContract, Ownable, ExposedStorage {
    using {findNextInitializedTick, findPrevInitializedTick, flipTick} for mapping(uint256 word => Bitmap bitmap);

    uint256 internal constant _LOCKER_COUNT_SLOT = 0;
    uint256 internal constant _LOCKER_ADDRESSES_OFFSET = 0x100000000;
    uint256 internal constant _NONZERO_DEBT_COUNT_OFFSET = 0x200000000;

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

    constructor(address owner, uint256 expirationTime) ExpiringContract(expirationTime) {
        _initializeOwner(owner);
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

    function getLocker() private view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(_LOCKER_COUNT_SLOT), 1)
            locker := tload(add(_LOCKER_ADDRESSES_OFFSET, id))
        }
        if (id == type(uint256).max) revert NotLocked();
    }

    function requireLocker() private view returns (uint256 id, address locker) {
        (id, locker) = getLocker();
        if (locker != msg.sender) revert LockerOnly();
    }

    // Negative means erasing debt, positive means adding debt
    function accountDebt(uint256 id, address token, int256 debtChange) private {
        assembly ("memory-safe") {
            if iszero(iszero(debtChange)) {
                mstore(0, add(shl(160, id), token))
                let deltaSlot := keccak256(0, 32)
                let current := tload(deltaSlot)

                // we know this never overflows because debtChange is only ever derived from 128 bit values in this contract
                let next := add(current, debtChange)

                let nextZero := iszero(next)
                if xor(iszero(current), nextZero) {
                    let nzdCountSlot := add(id, _NONZERO_DEBT_COUNT_OFFSET)

                    tstore(nzdCountSlot, add(sub(tload(nzdCountSlot), nextZero), iszero(nextZero)))
                }

                tstore(deltaSlot, next)
            }
        }
    }

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(_LOCKER_COUNT_SLOT)
            // store the count
            tstore(_LOCKER_COUNT_SLOT, add(id, 1))
            // store the address of the locker
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), caller())
        }

        // We make the assumption that this code can never be called recursively this many times, causing storage slots to overlap
        // This is just the codified assumption
        assert(id < type(uint32).max);

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDebtCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(_LOCKER_COUNT_SLOT, id)
            // remove the address
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDebtCount := tload(add(_NONZERO_DEBT_COUNT_OFFSET, id))
        }

        if (nonzeroDebtCount != 0) revert DebtsNotZeroed();
    }

    function forward(address to, bytes calldata data) external returns (bytes memory result) {
        (uint256 id, address locker) = requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), to)
        }

        result = IForwardee(to).forwarded(locker, id, data);

        assembly ("memory-safe") {
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), locker)
        }
    }

    function initializePool(PoolKey memory poolKey, int32 tick) external expires returns (uint256 sqrtRatio) {
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

    uint256 constant PAYMENT_LIMIT = 1 << 255;

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

            // no custom error because this is not possible under the assumption tokens have total supplies l.t. 2**128
            require(payment < PAYMENT_LIMIT);

            // The unary negative operator never fails because payment is less than max int256
            accountDebt(id, token, -int256(payment));
        }
    }

    function load(address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = getLocker();

        unchecked {
            uint256 balance = savedBalances[msg.sender][token][salt];
            if (balance < amount) {
                revert InsufficientSavedBalance();
            }
            savedBalances[msg.sender][token][salt] = balance - amount;
        }

        accountDebt(id, token, -int256(uint256(amount)));

        emit LoadedBalance(msg.sender, token, salt, amount);
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

        savedBalances[owner][token][salt] += amount;
        accountDebt(id, token, int256(uint256(amount)));

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
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external expires {
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
        expiresIff(params.liquidityDelta > 0)
        returns (int128 delta0, int128 delta1)
    {
        (uint256 id, address locker) = requireLocker();

        if (shouldCallBeforeUpdatePosition(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).beforeUpdatePosition(locker, poolKey, params);
        }

        params.bounds.validateBounds(poolKey.tickSpacing);

        if (params.liquidityDelta != 0) {
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
                    unchecked {
                        // uint128(-delta0) is ok in unchecked block
                        uint128 amount0Fee = computeFee(uint128(-delta0), poolKey.fee);
                        uint128 amount1Fee = computeFee(uint128(-delta1), poolKey.fee);
                        // this will never overflow for a well behaved token since protocol fees are stored as uint256
                        if (amount0Fee > 0) {
                            protocolFeesCollected[poolKey.token0] += amount0Fee;
                        }
                        if (amount1Fee > 0) {
                            protocolFeesCollected[poolKey.token1] += amount1Fee;
                        }
                        // delta is at most equal to -(amount fee), so this will maximally reach 0 and no overflow/underflow check is needed
                        // in addition, casting is safe because computed fee is never g.t. the input amount
                        delta0 += int128(amount0Fee);
                        delta1 += int128(amount1Fee);
                        emit ProtocolFeesPaid(poolKey, positionKey, amount0Fee, amount1Fee);
                    }
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
        expires
        returns (int128 delta0, int128 delta1)
    {
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

                // this accounts the fees into the feesPerLiquidity memory struct
                assembly ("memory-safe") {
                    // div by 0 returns 0, so it's ok
                    let v := div(shl(128, mload(add(result, 96))), liquidity)
                    let s := add(feesPerLiquidity, mul(increasing, 32))
                    mstore(s, add(mload(s), v))
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
                            : subLiquidityDelta(liquidity, liquidityDelta);
                        tickFeesPerLiquidityOutside[nextTick] =
                            feesPerLiquidity.sub(tickFeesPerLiquidityOutside[nextTick]);
                    }
                } else if (sqrtRatio != result.sqrtRatioNext) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = sqrtRatioToTick(sqrtRatio);
                }
            }

            unchecked {
                int256 calculatedAmountSign = int256(FixedPointMathLib.ternary(params.amount < 0, 1, type(uint256).max));
                int128 calculatedAmountDelta =
                    SafeCastLib.toInt128(calculatedAmountSign * int256(uint256(calculatedAmount)));

                (delta0, delta1) = params.isToken1
                    ? (calculatedAmountDelta, params.amount - amountRemaining)
                    : (params.amount - amountRemaining, calculatedAmountDelta);
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

        // Assumption that msg.value will never overflow this cast
        unchecked {
            accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
        }
    }
}
