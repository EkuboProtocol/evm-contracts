// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionKey, Bounds} from "./types/positionKey.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "./types/feesPerLiquidity.sol";
import {isPriceIncreasing, SqrtRatioLimitWrongDirection, SwapResult, swapResult} from "./math/swap.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "./math/ticks.sol";
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
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {liquidityDeltaToAmountDelta, addLiquidityDelta, subLiquidityDelta} from "./math/liquidity.sol";
import {findNextInitializedTick, findPrevInitializedTick, flipTick} from "./math/tickBitmap.sol";
import {ICore, UpdatePositionParameters, IExtension} from "./interfaces/ICore.sol";
import {FlashAccountant} from "./base/FlashAccountant.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "./math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "./types/sqrtRatio.sol";

/// @title Ekubo Protocol
/// @author Moody Salem <moody@ekubo.org>
/// @notice Singleton holding all the tokens and containing all the possible operations in Ekubo Protocol
contract Core is ICore, FlashAccountant, ExposedStorage {
    using {findNextInitializedTick, findPrevInitializedTick, flipTick} for mapping(uint256 word => Bitmap bitmap);

    struct TickInfo {
        int128 liquidityDelta;
        uint128 liquidityNet;
    }

    struct PoolState {
        SqrtRatio sqrtRatio;
        int32 tick;
        uint128 liquidity;
    }

    mapping(address extension => bool isRegistered) private isExtensionRegistered;

    mapping(bytes32 poolId => PoolState) private poolState;
    mapping(bytes32 poolId => FeesPerLiquidity feesPerLiquidity) private poolFeesPerLiquidity;
    mapping(bytes32 poolId => mapping(bytes32 positionId => Position position)) private poolPositions;
    mapping(bytes32 poolId => mapping(int32 tick => TickInfo tickInfo)) private poolTicks;
    mapping(bytes32 poolId => mapping(int32 tick => FeesPerLiquidity feesPerLiquidityOutside)) private
        poolTickFeesPerLiquidityOutside;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) private poolInitializedTickBitmaps;

    mapping(bytes32 key => uint256) private savedBalances;

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) {
            revert FailedRegisterInvalidCallPoints();
        }
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;
        emit ExtensionRegistered(msg.sender);
    }

    function initializePool(PoolKey memory poolKey, int32 tick) external returns (SqrtRatio sqrtRatio) {
        poolKey.validatePoolKey();

        address extension = poolKey.extension();
        if (extension != address(0)) {
            if (!isExtensionRegistered[extension]) {
                revert ExtensionNotRegistered();
            }

            if (shouldCallBeforeInitializePool(extension) && extension != msg.sender) {
                IExtension(extension).beforeInitializePool(msg.sender, poolKey, tick);
            }
        }

        bytes32 poolId = poolKey.toPoolId();
        PoolState memory price = poolState[poolId];
        if (SqrtRatio.unwrap(price.sqrtRatio) != 0) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        poolState[poolId] = PoolState({sqrtRatio: sqrtRatio, tick: tick, liquidity: 0});

        emit PoolInitialized(poolId, poolKey, tick, sqrtRatio);

        if (shouldCallAfterInitializePool(extension) && extension != msg.sender) {
            IExtension(extension).afterInitializePool(msg.sender, poolKey, tick, sqrtRatio);
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

    function updateSavedBalances(
        address token0,
        address token1,
        bytes32,
        // positive is saving, negative is loading
        int256 delta0,
        int256 delta1
    ) public payable {
        if (token0 >= token1) revert SavedBalanceTokensNotSorted();

        (uint256 id, address locker) = _requireLocker();

        assembly ("memory-safe") {
            function addDelta(u, i) -> result {
                // full‐width sum mod 2^256
                let sum := add(u, i)
                // 1 if i<0 else 0
                let sign := shr(255, i)
                // if sum > type(uint128).max || (i>=0 && sum<u) || (i<0 && sum>u) ⇒ 256-bit wrap or underflow
                if or(shr(128, sum), or(and(iszero(sign), lt(sum, u)), and(sign, gt(sum, u)))) {
                    mstore(0x00, 0x1293d6fa) // `SavedBalanceOverflow()`
                    revert(0x1c, 0x04)
                }
                result := sum
            }

            let free := mload(0x40)
            mstore(free, locker)
            // copy the first 3 arguments in the same order
            calldatacopy(add(free, 0x20), 4, 96)
            mstore(0, keccak256(free, 128))
            mstore(32, 7)
            let slot := keccak256(0, 64)
            let balances := sload(slot)

            let b0 := shr(128, balances)
            let b1 := shr(128, shl(128, balances))

            let b0Next := addDelta(b0, delta0)
            let b1Next := addDelta(b1, delta1)

            sstore(slot, add(shl(128, b0Next), b1Next))
        }

        _maybeAccountDebtToken0(id, token0, delta0);
        _accountDebt(id, token1, delta1);
    }

    // Returns the pool fees per liquidity inside the given bounds.
    function _getPoolFeesPerLiquidityInside(bytes32 poolId, Bounds memory bounds, uint32 tickSpacing)
        internal
        view
        returns (FeesPerLiquidity memory)
    {
        if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) return poolFeesPerLiquidity[poolId];

        int32 tick = poolState[poolId].tick;
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

    function getPoolFeesPerLiquidityInside(PoolKey memory poolKey, Bounds memory bounds)
        external
        view
        returns (FeesPerLiquidity memory)
    {
        return _getPoolFeesPerLiquidityInside(poolKey.toPoolId(), bounds, poolKey.tickSpacing());
    }

    // Accumulates tokens to fees of a pool. Only callable by the extension of the specified pool
    // key, i.e. the current locker _must_ be the extension.
    // The extension must call this function within a lock callback.
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external payable {
        (uint256 id, address locker) = _requireLocker();
        require(locker == poolKey.extension());

        bytes32 poolId = poolKey.toPoolId();

        // Note we do not check pool is initialized. If the extension calls this for a pool that does not exist,
        //  the fees are simply burned since liquidity is 0.

        assembly ("memory-safe") {
            if or(amount0, amount1) {
                mstore(0, poolId)
                mstore(32, 1)
                let liquidity := shr(128, sload(keccak256(0, 64)))

                if liquidity {
                    mstore(32, 2)
                    let slot0 := keccak256(0, 64)

                    if amount0 {
                        let v := div(shl(128, amount0), liquidity)
                        sstore(slot0, add(sload(slot0), v))
                    }
                    if amount1 {
                        let slot1 := add(slot0, 1)
                        let v := div(shl(128, amount1), liquidity)
                        sstore(slot1, add(sload(slot1), v))
                    }
                }
            }
        }

        // whether the fees are actually accounted to any position, the caller owes the debt
        _maybeAccountDebtToken0(id, poolKey.token0, int256(uint256(amount0)));
        _accountDebt(id, poolKey.token1, int256(uint256(amount1)));

        emit FeesAccumulated(poolId, amount0, amount1);
    }

    function _updateTick(bytes32 poolId, int32 tick, uint32 tickSpacing, int128 liquidityDelta, bool isUpper) private {
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

    function _maybeAccountDebtToken0(uint256 id, address token0, int256 debtChange) private {
        if (msg.value == 0) {
            _accountDebt(id, token0, debtChange);
        } else {
            if (msg.value > type(uint128).max) revert PaymentOverflow();

            if (token0 == NATIVE_TOKEN_ADDRESS) {
                unchecked {
                    _accountDebt(id, NATIVE_TOKEN_ADDRESS, debtChange - int256(msg.value));
                }
            } else {
                unchecked {
                    _accountDebt(id, token0, debtChange);
                    _accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
                }
            }
        }
    }

    function updatePosition(PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        (uint256 id, address locker) = _requireLocker();

        address extension = poolKey.extension();
        if (shouldCallBeforeUpdatePosition(extension) && locker != extension) {
            IExtension(extension).beforeUpdatePosition(locker, poolKey, params);
        }

        params.bounds.validateBounds(poolKey.tickSpacing());

        if (params.liquidityDelta != 0) {
            bytes32 poolId = poolKey.toPoolId();
            PoolState memory price = poolState[poolId];
            if (SqrtRatio.unwrap(price.sqrtRatio) == 0) revert PoolNotInitialized();

            (SqrtRatio sqrtRatioLower, SqrtRatio sqrtRatioUpper) =
                (tickToSqrtRatio(params.bounds.lower), tickToSqrtRatio(params.bounds.upper));

            (delta0, delta1) =
                liquidityDeltaToAmountDelta(price.sqrtRatio, params.liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

            PositionKey memory positionKey = PositionKey({salt: params.salt, owner: locker, bounds: params.bounds});

            bytes32 positionId = positionKey.toPositionId();
            Position storage position = poolPositions[poolId][positionId];

            FeesPerLiquidity memory feesPerLiquidityInside =
                _getPoolFeesPerLiquidityInside(poolId, params.bounds, poolKey.tickSpacing());

            (uint128 fees0, uint128 fees1) = position.fees(feesPerLiquidityInside);

            uint128 liquidityNext = addLiquidityDelta(position.liquidity, params.liquidityDelta);

            if (liquidityNext != 0) {
                position.liquidity = liquidityNext;
                position.feesPerLiquidityInsideLast =
                    feesPerLiquidityInside.sub(feesPerLiquidityFromAmounts(fees0, fees1, liquidityNext));
            } else {
                if (fees0 != 0 || fees1 != 0) revert MustCollectFeesBeforeWithdrawingAllLiquidity();
                position.liquidity = 0;
                position.feesPerLiquidityInsideLast = FeesPerLiquidity(0, 0);
            }

            if (!poolKey.isFullRange()) {
                _updateTick(poolId, params.bounds.lower, poolKey.tickSpacing(), params.liquidityDelta, false);
                _updateTick(poolId, params.bounds.upper, poolKey.tickSpacing(), params.liquidityDelta, true);

                if (price.tick >= params.bounds.lower && price.tick < params.bounds.upper) {
                    poolState[poolId].liquidity = addLiquidityDelta(poolState[poolId].liquidity, params.liquidityDelta);
                }
            } else {
                poolState[poolId].liquidity = addLiquidityDelta(poolState[poolId].liquidity, params.liquidityDelta);
            }

            _maybeAccountDebtToken0(id, poolKey.token0, delta0);
            _accountDebt(id, poolKey.token1, delta1);

            emit PositionUpdated(locker, poolId, params, delta0, delta1);
        }

        if (shouldCallAfterUpdatePosition(extension) && locker != extension) {
            IExtension(extension).afterUpdatePosition(locker, poolKey, params, delta0, delta1);
        }
    }

    function collectFees(PoolKey memory poolKey, bytes32 salt, Bounds memory bounds)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (uint256 id, address locker) = _requireLocker();

        address extension = poolKey.extension();
        if (shouldCallBeforeCollectFees(extension) && locker != extension) {
            IExtension(extension).beforeCollectFees(locker, poolKey, salt, bounds);
        }

        bytes32 poolId = poolKey.toPoolId();
        PositionKey memory positionKey = PositionKey({salt: salt, owner: locker, bounds: bounds});
        bytes32 positionId = positionKey.toPositionId();
        Position memory position = poolPositions[poolId][positionId];

        FeesPerLiquidity memory feesPerLiquidityInside =
            _getPoolFeesPerLiquidityInside(poolId, bounds, poolKey.tickSpacing());

        (amount0, amount1) = position.fees(feesPerLiquidityInside);

        poolPositions[poolId][positionId] =
            Position({liquidity: position.liquidity, feesPerLiquidityInsideLast: feesPerLiquidityInside});

        _accountDebt(id, poolKey.token0, -int256(uint256(amount0)));
        _accountDebt(id, poolKey.token1, -int256(uint256(amount1)));

        emit PositionFeesCollected(poolId, positionKey, amount0, amount1);

        if (shouldCallAfterCollectFees(extension) && locker != extension) {
            IExtension(extension).afterCollectFees(locker, poolKey, salt, bounds, amount0, amount1);
        }
    }

    function swap_611415377(
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external payable returns (int128 delta0, int128 delta1) {
        if (!sqrtRatioLimit.isValid()) revert InvalidSqrtRatioLimit();

        (uint256 id, address locker) = _requireLocker();

        address extension = poolKey.extension();
        if (shouldCallBeforeSwap(extension) && locker != extension) {
            IExtension(extension).beforeSwap(locker, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
        }

        bytes32 poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio;
        int32 tick;
        uint128 liquidity;
        {
            PoolState storage state = poolState[poolId];
            (sqrtRatio, tick, liquidity) = (state.sqrtRatio, state.tick, state.liquidity);
        }

        if (sqrtRatio.isZero()) revert PoolNotInitialized();

        // 0 swap amount is no-op
        if (amount != 0) {
            bool increasing = isPriceIncreasing(amount, isToken1);
            if (increasing) {
                if (sqrtRatioLimit < sqrtRatio) revert SqrtRatioLimitWrongDirection();
            } else {
                if (sqrtRatioLimit > sqrtRatio) revert SqrtRatioLimitWrongDirection();
            }

            int128 amountRemaining = amount;

            uint128 calculatedAmount = 0;

            // the slot where inputTokenFeesPerLiquidity is stored, reused later
            bytes32 inputTokenFeesPerLiquiditySlot;

            // fees per liquidity only for the input token
            uint256 inputTokenFeesPerLiquidity;

            // this loads only the input token fees per liquidity
            if (poolKey.mustLoadFees()) {
                assembly ("memory-safe") {
                    mstore(0, poolId)
                    mstore(32, 2)
                    inputTokenFeesPerLiquiditySlot := add(keccak256(0, 64), increasing)
                    inputTokenFeesPerLiquidity := sload(inputTokenFeesPerLiquiditySlot)
                }
            }

            while (amountRemaining != 0 && sqrtRatio != sqrtRatioLimit) {
                int32 nextTick;
                bool isInitialized;
                SqrtRatio nextTickSqrtRatio;
                SwapResult memory result;

                if (poolKey.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) {
                    (nextTick, isInitialized) = increasing
                        ? poolInitializedTickBitmaps[poolId].findNextInitializedTick(tick, poolKey.tickSpacing(), skipAhead)
                        : poolInitializedTickBitmaps[poolId].findPrevInitializedTick(tick, poolKey.tickSpacing(), skipAhead);

                    nextTickSqrtRatio = tickToSqrtRatio(nextTick);
                } else {
                    // we never cross ticks in the full range version
                    // isInitialized = false;
                    (nextTick, nextTickSqrtRatio) = increasing ? (MAX_TICK, MAX_SQRT_RATIO) : (MIN_TICK, MIN_SQRT_RATIO);
                }

                SqrtRatio limitedNextSqrtRatio =
                    increasing ? nextTickSqrtRatio.min(sqrtRatioLimit) : nextTickSqrtRatio.max(sqrtRatioLimit);

                result =
                    swapResult(sqrtRatio, liquidity, limitedNextSqrtRatio, amountRemaining, isToken1, poolKey.fee());

                // this accounts the fees into the feesPerLiquidity memory struct
                assembly ("memory-safe") {
                    // div by 0 returns 0, so it's ok
                    let v := div(shl(128, mload(add(result, 96))), liquidity)
                    inputTokenFeesPerLiquidity := add(inputTokenFeesPerLiquidity, v)
                }

                amountRemaining -= result.consumedAmount;
                calculatedAmount += result.calculatedAmount;

                if (result.sqrtRatioNext == nextTickSqrtRatio) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = increasing ? nextTick : nextTick - 1;

                    if (isInitialized) {
                        int128 liquidityDelta = poolTicks[poolId][nextTick].liquidityDelta;
                        liquidity = increasing
                            ? addLiquidityDelta(liquidity, liquidityDelta)
                            : subLiquidityDelta(liquidity, liquidityDelta);
                        FeesPerLiquidity memory tickFpl = poolTickFeesPerLiquidityOutside[poolId][nextTick];

                        FeesPerLiquidity memory totalFpl;

                        // load only the slot we didn't load before into totalFpl
                        assembly ("memory-safe") {
                            mstore(add(totalFpl, mul(32, increasing)), inputTokenFeesPerLiquidity)

                            let outputTokenFeesPerLiquidity :=
                                sload(add(sub(inputTokenFeesPerLiquiditySlot, increasing), iszero(increasing)))
                            mstore(add(totalFpl, mul(32, iszero(increasing))), outputTokenFeesPerLiquidity)
                        }

                        poolTickFeesPerLiquidityOutside[poolId][nextTick] = totalFpl.sub(tickFpl);
                    }
                } else if (sqrtRatio != result.sqrtRatioNext) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = sqrtRatioToTick(sqrtRatio);
                }
            }

            unchecked {
                int256 calculatedAmountSign = int256(FixedPointMathLib.ternary(amount < 0, 1, type(uint256).max));
                int128 calculatedAmountDelta = SafeCastLib.toInt128(
                    FixedPointMathLib.max(type(int128).min, calculatedAmountSign * int256(uint256(calculatedAmount)))
                );

                (delta0, delta1) = isToken1
                    ? (calculatedAmountDelta, amount - amountRemaining)
                    : (amount - amountRemaining, calculatedAmountDelta);
            }

            assembly ("memory-safe") {
                mstore(0, poolId)
                mstore(32, 1)
                sstore(keccak256(0, 64), add(add(sqrtRatio, shl(96, and(tick, 0xffffffff))), shl(128, liquidity)))
            }

            if (poolKey.mustLoadFees()) {
                assembly ("memory-safe") {
                    // this stores only the input token fees per liquidity
                    sstore(inputTokenFeesPerLiquiditySlot, inputTokenFeesPerLiquidity)
                }
            }

            _maybeAccountDebtToken0(id, poolKey.token0, delta0);
            _accountDebt(id, poolKey.token1, delta1);

            assembly ("memory-safe") {
                let o := mload(0x40)
                mstore(o, shl(96, locker))
                // note we only emit the first 16 bytes of the pool ID because it's overwritten in the next mstore, 16 bytes * 8 gas = 128 gas saved per swap
                // off chain, the indexers must match by prefix. in case of a collision, this can cause swaps to be misattributed, but a collision is very unlikely.
                mstore(add(o, 20), poolId)
                mstore(add(o, 36), or(shl(128, delta0), and(delta1, 0xffffffffffffffffffffffffffffffff)))
                mstore(add(o, 68), shl(128, liquidity))
                mstore(add(o, 84), shl(160, sqrtRatio))
                mstore(add(o, 96), shl(224, tick))
                log0(o, 100)
            }
        }

        if (shouldCallAfterSwap(extension) && locker != extension) {
            IExtension(extension).afterSwap(
                locker, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead, delta0, delta1
            );
        }
    }
}
