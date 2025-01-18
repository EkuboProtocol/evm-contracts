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
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {computeFee} from "./math/fee.sol";
import {findNextInitializedTick, findPrevInitializedTick, flipTick} from "./math/tickBitmap.sol";
import {TransfersTokens} from "./base/TransfersTokens.sol";

interface ILocker {
    function locked(uint256 id, bytes calldata data) external returns (bytes memory);
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

// Common storage getters we need for external contracts are defined here instead of in the core contract
library CoreLib {
    function poolPrice(Core core, bytes32 poolId) internal view returns (uint192 sqrtRatio, int32 tick) {
        bytes32 result = core.sload(keccak256(abi.encodePacked(poolId, uint256(2))));
        assembly {
            sqrtRatio := and(result, 0xffffffffffffffffffffffffffffffffffffffffffffffff)
            tick := shr(192, result)
        }
    }

    function poolLiquidity(Core core, bytes32 poolId) internal view returns (uint128 liquidity) {
        bytes32 result = core.sload(keccak256(abi.encodePacked(poolId, uint256(3))));
        assembly {
            liquidity := and(result, 0xffffffffffffffffffffffffffffffff)
        }
    }
}

contract Core is Ownable, ExposedStorage, TransfersTokens {
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

    // Keyed by the pool ID, which is the keccak256 of the ABI-encoded pool key
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

    constructor(address owner) {
        _initializeOwner(owner);
    }

    event ProtocolFeesWithdrawn(address recipient, address token, uint256 amount);

    function withdrawProtocolFees(address recipient, address token, uint256 amount) external onlyOwner {
        protocolFeesCollected[token] -= amount;
        transferToken(token, recipient, amount);
        emit ProtocolFeesWithdrawn(recipient, token, amount);
    }

    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();

    event ExtensionRegistered(address extension);

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) revert FailedRegisterInvalidCallPoints();
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;

        emit ExtensionRegistered(msg.sender);
    }

    error LockerOnly();

    function requireLocker() private view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(0), 1)
            locker := tload(add(0x100000000, id))
        }
        if (locker != msg.sender) revert LockerOnly();
    }

    function accountDelta(uint256 id, address token, int256 delta) private {
        if (delta == 0) return;
        bytes32 slot = keccak256(abi.encode(id, token));

        int256 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }

        // this is a checked addition, so it will revert if it overflows
        int256 next = current + delta;

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

    error DeltasNotZeroed(uint256 count);

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

        uint256 nonzeroDeltaCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(0, id)
            // remove the address
            tstore(add(0x100000000, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDeltaCount := tload(add(0x200000000, id))
        }

        if (nonzeroDeltaCount != 0) revert DeltasNotZeroed(nonzeroDeltaCount);
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

    error PoolAlreadyInitialized();
    error ExtensionNotRegistered(address extension);

    event PoolInitialized(PoolKey key, int32 tick, uint256 sqrtRatio);

    function initializePool(PoolKey memory key, int32 tick) public returns (uint256 sqrtRatio) {
        key.validatePoolKey();

        if (key.extension != address(0)) {
            if (!isExtensionRegistered[key.extension]) {
                revert ExtensionNotRegistered(key.extension);
            }

            if (shouldCallBeforeInitializePool(key.extension) && key.extension != msg.sender) {
                IExtension(key.extension).beforeInitializePool(msg.sender, key, tick);
            }
        }

        bytes32 poolId = key.toPoolId();
        PoolPrice memory price = poolPrice[poolId];
        if (price.sqrtRatio != 0) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        poolPrice[poolId] = PoolPrice({sqrtRatio: uint192(sqrtRatio), tick: tick});

        emit PoolInitialized(key, tick, sqrtRatio);

        if (shouldCallAfterInitializePool(key.extension) && key.extension != msg.sender) {
            IExtension(key.extension).afterInitializePool(msg.sender, key, tick, sqrtRatio);
        }
    }

    using {findNextInitializedTick, findPrevInitializedTick, flipTick} for mapping(uint256 word => Bitmap bitmap);

    function prevInitializedTick(PoolKey memory poolKey, int32 fromTick, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) = poolInitializedTickBitmaps[poolKey.toPoolId()].findPrevInitializedTick(
            fromTick, poolKey.tickSpacing, skipAhead
        );
    }

    function nextInitializedTick(PoolKey memory poolKey, int32 fromTick, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) = poolInitializedTickBitmaps[poolKey.toPoolId()].findNextInitializedTick(
            fromTick, poolKey.tickSpacing, skipAhead
        );
    }

    error BalanceDeltaNotEqualAllowance(address token);
    error AllowanceOverflow(address token, uint256 delta);

    error BalanceTooGreat();

    uint256 constant MAX_BALANCE = type(uint256).max >> 1; // == (1<<255) - 1

    function startPayment(address token) external {
        uint256 tokenBalance = balanceOfToken(token);
        if (tokenBalance > MAX_BALANCE) revert BalanceTooGreat();
        assembly ("memory-safe") {
            tstore(
                add(0xb2167327b5ed4f50eaa3f30a1543bbcd48e24d90dc0da6920d198e2eedf81ef7, token),
                // sets the most significant bit in the token balance which we know is not set because we checked tokenBalance < MAX_BALANCE
                or(0x8000000000000000000000000000000000000000000000000000000000000000, tokenBalance)
            )
        }
    }

    error NoPaymentMade();
    error CallStartPaymentFirst();

    function completePayment(address token) external payable {
        (uint256 id,) = requireLocker();

        uint256 previousBalance;
        assembly ("memory-safe") {
            let slot := add(0xb2167327b5ed4f50eaa3f30a1543bbcd48e24d90dc0da6920d198e2eedf81ef7, token)
            previousBalance := sub(tload(slot), 0x8000000000000000000000000000000000000000000000000000000000000000)
            tstore(slot, 0)
        }

        // if we know the actual balance is less than (1<<255),
        // then subtracting the value (1<<255) will necessarily underflow to a value that is greater than or equal to (1<<255)
        if (previousBalance >= MAX_BALANCE) revert CallStartPaymentFirst();

        uint256 balance = balanceOfToken(token);
        if (balance <= previousBalance) {
            revert NoPaymentMade();
        }

        unchecked {
            uint256 payment = balance - previousBalance;

            // no safe cast necessary because payment is necessarily less than MAX_BALANCE which is 255 bits
            accountDelta(id, token, -int256(payment));
        }
    }

    event LoadedBalance(address owner, address token, bytes32 salt, uint128 amount);

    function load(address token, bytes32 salt, uint128 amount) external {
        (uint256 id, address owner) = requireLocker();

        accountDelta(id, token, -int256(uint256(amount)));

        savedBalances[owner][token][salt] -= amount;

        emit LoadedBalance(owner, token, salt, amount);
    }

    error TokenAmountTooLarge();

    function withdraw(address token, address recipient, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDelta(id, token, int256(uint256(amount)));

        transferToken(token, recipient, amount);
    }

    event SavedBalance(address owner, address token, bytes32 salt, uint128 amount);

    function save(address owner, address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDelta(id, token, int256(uint256(amount)));

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

    error OnlyCallableByExtension();
    error CannotAccumulateFeesWithZeroLiquidity();

    event FeesAccumulated(PoolKey poolKey, uint128 amount0, uint128 amount1);

    // Accumulates tokens to fees of a pool. Only callable by the extension of the specified pool
    // key, i.e. the current locker _must_ be the extension.
    // The extension must call this function within a lock callback.
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external {
        (uint256 id, address locker) = requireLocker();
        if (locker != poolKey.extension) revert OnlyCallableByExtension();
        bytes32 poolId = poolKey.toPoolId();
        uint128 liquidity = poolLiquidity[poolId];
        if (liquidity == 0) revert CannotAccumulateFeesWithZeroLiquidity();

        poolFeesPerLiquidity[poolKey.toPoolId()] =
            poolFeesPerLiquidity[poolId].add(feesPerLiquidityFromAmounts(amount0, amount1, liquidity));

        accountDelta(id, poolKey.token0, int256(uint256(amount0)));
        accountDelta(id, poolKey.token1, int256(uint256(amount1)));

        emit FeesAccumulated(poolKey, amount0, amount1);
    }

    error LiquidityUnderflow();
    error LiquidityOverflow();

    function addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) private pure returns (uint128) {
        unchecked {
            int256 l = int256(uint256(liquidity));
            int256 lNext = l + liquidityDelta;

            if (lNext < 0) revert LiquidityUnderflow();
            if (lNext > type(int128).max) revert LiquidityOverflow();

            return uint128(int128(lNext));
        }
    }

    function updateTick(bytes32 poolId, int32 tick, uint32 tickSpacing, int128 liquidityDelta, bool isUpper) private {
        TickInfo storage tickInfo = poolTicks[poolId][tick];

        // todo: can we optimize this so it's only one sload?

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

    error PoolNotInitialized();

    error MustCollectFeesBeforeWithdrawingAllLiquidity();

    event PositionUpdated(PoolKey poolKey, UpdatePositionParameters params, int128 delta0, int128 delta1);
    event ProtocolFeesPaid(PoolKey poolKey, PositionKey positionKey, uint128 amount0, uint128 amount1);

    function updatePosition(PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        returns (int128 delta0, int128 delta1)
    {
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

            accountDelta(id, poolKey.token0, delta0);
            accountDelta(id, poolKey.token1, delta1);

            emit PositionUpdated(poolKey, params, delta0, delta1);
        }

        if (shouldCallAfterUpdatePosition(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterUpdatePosition(locker, poolKey, params, delta0, delta1);
        }
    }

    event PositionFeesCollected(PoolKey poolKey, PositionKey positionKey, uint128 amount0, uint128 amount1);

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

        accountDelta(id, poolKey.token0, int256(uint256(amount0)));
        accountDelta(id, poolKey.token1, int256(uint256(amount1)));

        emit PositionFeesCollected(poolKey, positionKey, amount0, amount1);

        if (shouldCallAfterCollectFees(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterCollectFees(locker, poolKey, salt, bounds, amount0, amount1);
        }
    }

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

    error SqrtRatioLimitWrongDirection();
    error SqrtRatioLimitOutOfRange();

    function swap(PoolKey memory poolKey, SwapParameters memory params)
        external
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
            PoolPrice memory price = poolPrice[poolId];
            sqrtRatio = price.sqrtRatio;
            if (sqrtRatio == 0) revert PoolNotInitialized();
            tick = price.tick;
        }

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

                // todo: should we do this math unchecked?
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

            accountDelta(id, poolKey.token0, delta0);
            accountDelta(id, poolKey.token1, delta1);

            emit Swapped(locker, poolKey, params, delta0, delta1, sqrtRatio, tick, liquidity);
        }

        if (shouldCallAfterSwap(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterSwap(locker, poolKey, params, delta0, delta1);
        }
    }
}
