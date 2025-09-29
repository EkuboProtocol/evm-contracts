// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionId} from "./types/positionId.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "./types/feesPerLiquidity.sol";
import {isPriceIncreasing} from "./math/isPriceIncreasing.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "./math/ticks.sol";
import {CoreStorageLayout} from "./libraries/CoreStorageLayout.sol";
import {ExtensionCallPointsLib} from "./libraries/ExtensionCallPointsLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {liquidityDeltaToAmountDelta, addLiquidityDelta, subLiquidityDelta} from "./math/liquidity.sol";
import {findNextInitializedTick, findPrevInitializedTick, flipTick} from "./math/tickBitmap.sol";
import {ICore, IExtension} from "./interfaces/ICore.sol";
import {FlashAccountant} from "./base/FlashAccountant.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "./math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "./types/sqrtRatio.sol";
import {PoolState, createPoolState} from "./types/poolState.sol";
import {TickInfo, createTickInfo} from "./types/tickInfo.sol";
import {PoolId} from "./types/poolId.sol";
import {Locker} from "./types/locker.sol";
import {computeFee, amountBeforeFee} from "./math/fee.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "./math/sqrtRatio.sol";
import {amount0Delta, amount1Delta} from "./math/delta.sol";

/// @title Ekubo Protocol Core
/// @author Moody Salem <moody@ekubo.org>
/// @notice Singleton contract holding all tokens and containing all possible operations in Ekubo Protocol
/// @dev Implements the core AMM functionality including pools, positions, swaps, and fee collection
contract Core is ICore, FlashAccountant, ExposedStorage {
    using ExtensionCallPointsLib for *;

    /// @inheritdoc ICore
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) {
            revert FailedRegisterInvalidCallPoints();
        }
        bytes32 isExtensionRegisteredSlot = CoreStorageLayout.isExtensionRegisteredSlot(msg.sender);
        bool isExtensionRegistered;
        assembly ("memory-safe") {
            isExtensionRegistered := sload(isExtensionRegisteredSlot)
        }
        if (isExtensionRegistered) revert ExtensionAlreadyRegistered();

        assembly ("memory-safe") {
            sstore(isExtensionRegisteredSlot, 1)
        }

        emit ExtensionRegistered(msg.sender);
    }

    function readPoolState(PoolId poolId) internal view returns (PoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function writePoolState(PoolId poolId, PoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }

    /// @inheritdoc ICore
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (SqrtRatio sqrtRatio) {
        poolKey.validatePoolKey();

        address extension = poolKey.extension();
        if (extension != address(0)) {
            bytes32 isExtensionRegisteredSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
            bool isExtensionRegistered;
            assembly ("memory-safe") {
                isExtensionRegistered := sload(isExtensionRegisteredSlot)
            }

            if (!isExtensionRegistered) {
                revert ExtensionNotRegistered();
            }

            IExtension(extension).maybeCallBeforeInitializePool(msg.sender, poolKey, tick);
        }

        PoolId poolId = poolKey.toPoolId();
        PoolState state = readPoolState(poolId);
        if (state.isInitialized()) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        writePoolState(poolId, createPoolState({_sqrtRatio: sqrtRatio, _tick: tick, _liquidity: 0}));

        emit PoolInitialized(poolId, poolKey, tick, sqrtRatio);

        IExtension(extension).maybeCallAfterInitializePool(msg.sender, poolKey, tick, sqrtRatio);
    }

    /// @inheritdoc ICore
    function prevInitializedTick(PoolId poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            findPrevInitializedTick(CoreStorageLayout.tickBitmapsSlot(poolId), fromTick, tickSpacing, skipAhead);
    }

    /// @inheritdoc ICore
    function nextInitializedTick(PoolId poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            findNextInitializedTick(CoreStorageLayout.tickBitmapsSlot(poolId), fromTick, tickSpacing, skipAhead);
    }

    /// @inheritdoc ICore
    function updateSavedBalances(
        address token0,
        address token1,
        bytes32,
        // positive is saving, negative is loading
        int256 delta0,
        int256 delta1
    ) public payable {
        if (token0 >= token1) revert SavedBalanceTokensNotSorted();

        (uint256 id, address lockerAddr) = _requireLocker().parse();

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

            // we can cheaply calldatacopy the arguments into memory, hence no call to CoreStorageLayout#savedBalancesSlot
            let free := mload(0x40)
            mstore(free, lockerAddr)
            // copy the first 3 arguments in the same order
            calldatacopy(add(free, 0x20), 4, 96)
            let slot := keccak256(free, 128)
            let balances := sload(slot)

            let b0 := shr(128, balances)
            let b1 := shr(128, shl(128, balances))

            let b0Next := addDelta(b0, delta0)
            let b1Next := addDelta(b1, delta1)

            sstore(slot, add(shl(128, b0Next), b1Next))
        }

        _updatePairDebtWithNative(id, token0, token1, delta0, delta1);
    }

    /// @notice Returns the pool fees per liquidity inside the given bounds
    /// @dev Internal function that calculates fees per liquidity within position bounds
    /// @param poolId Unique identifier for the pool
    /// @param tickLower Lower tick of the price range to get the snapshot of
    /// @param tickLower Upper tick of the price range to get the snapshot of
    /// @param tickSpacing Tick spacing for the pool
    /// @return feesPerLiquidity Accumulated fees per liquidity inside the bounds
    function _getPoolFeesPerLiquidityInside(PoolId poolId, int32 tickLower, int32 tickUpper, uint32 tickSpacing)
        internal
        view
        returns (FeesPerLiquidity memory)
    {
        if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) {
            FeesPerLiquidity memory fpl;
            bytes32 fplFirstSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
            assembly ("memory-safe") {
                mstore(fpl, sload(fplFirstSlot))
                mstore(add(fpl, 0x20), sload(add(fplFirstSlot, 1)))
            }
            return fpl;
        }

        int32 tick = readPoolState(poolId).tick();

        FeesPerLiquidity memory lower;
        FeesPerLiquidity memory upper;

        (bytes32 lowerFirstSlot, bytes32 lowerSecondSlot) =
            CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tickLower);
        (bytes32 upperFirstSlot, bytes32 upperSecondSlot) =
            CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tickUpper);

        assembly ("memory-safe") {
            mstore(lower, sload(lowerFirstSlot))
            mstore(add(lower, 0x20), sload(lowerSecondSlot))

            mstore(upper, sload(upperFirstSlot))
            mstore(add(upper, 0x20), sload(upperSecondSlot))
        }

        if (tick < tickLower) {
            lower.subAssign(upper);
            return lower;
        } else if (tick < tickUpper) {
            FeesPerLiquidity memory fees;
            bytes32 fplFirstSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
            assembly ("memory-safe") {
                mstore(fees, sload(fplFirstSlot))
                mstore(add(fees, 0x20), sload(add(fplFirstSlot, 1)))
            }

            fees.subAssign(lower);
            fees.subAssign(upper);
            return fees;
        } else {
            upper.subAssign(lower);
            return upper;
        }
    }

    /// @inheritdoc ICore
    function getPoolFeesPerLiquidityInside(PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (FeesPerLiquidity memory)
    {
        return _getPoolFeesPerLiquidityInside(poolKey.toPoolId(), tickLower, tickUpper, poolKey.tickSpacing());
    }

    /// @inheritdoc ICore
    function accumulateAsFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external payable {
        (uint256 id, address lockerAddr) = _requireLocker().parse();
        require(lockerAddr == poolKey.extension());

        PoolId poolId = poolKey.toPoolId();

        // Note we do not check pool is initialized. If the extension calls this for a pool that does not exist,
        //  the fees are simply burned since liquidity is 0.

        assembly ("memory-safe") {
            if or(amount0, amount1) {
                let liquidity := shr(128, shl(128, sload(poolId)))

                if liquidity {
                    let slot0 := add(poolId, 1)

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
        _updatePairDebtWithNative(
            id, poolKey.token0, poolKey.token1, int256(uint256(amount0)), int256(uint256(amount1))
        );

        emit FeesAccumulated(poolId, amount0, amount1);
    }

    /// @notice Updates tick information when liquidity is added or removed
    /// @dev Private function that handles tick initialization and liquidity tracking
    /// @param poolId Unique identifier for the pool
    /// @param tick Tick to update
    /// @param tickSpacing Tick spacing for the pool
    /// @param liquidityDelta Change in liquidity
    /// @param isUpper Whether this is the upper bound of a position
    function _updateTick(PoolId poolId, int32 tick, uint32 tickSpacing, int128 liquidityDelta, bool isUpper) private {
        bytes32 slot = CoreStorageLayout.poolTicksSlot(poolId, tick);
        TickInfo ti;
        assembly ("memory-safe") {
            ti := sload(slot)
        }

        (int128 currentLiquidityDelta, uint128 currentLiquidityNet) = ti.parse();
        uint128 liquidityNetNext = addLiquidityDelta(currentLiquidityNet, liquidityDelta);
        // this is checked math
        int128 liquidityDeltaNext =
            isUpper ? currentLiquidityDelta - liquidityDelta : currentLiquidityDelta + liquidityDelta;

        if ((currentLiquidityNet == 0) != (liquidityNetNext == 0)) {
            flipTick(CoreStorageLayout.tickBitmapsSlot(poolId), tick, tickSpacing);
        }

        ti = createTickInfo(liquidityDeltaNext, liquidityNetNext);

        assembly ("memory-safe") {
            sstore(slot, ti)
        }
    }

    /// @notice Updates debt for a token pair, handling native token payments for token0
    /// @dev Optimized version that updates both tokens' debts in a single operation when possible.
    ///      Assumes token0 < token1 (tokens are sorted).
    /// @param id Lock ID for debt tracking
    /// @param token0 Address of token0 (must be < token1)
    /// @param token1 Address of token1 (must be > token0)
    /// @param debtChange0 Change in debt amount for token0
    /// @param debtChange1 Change in debt amount for token1
    function _updatePairDebtWithNative(
        uint256 id,
        address token0,
        address token1,
        int256 debtChange0,
        int256 debtChange1
    ) private {
        if (msg.value == 0) {
            // No native token payment included in the call, so use optimized pair update
            _updatePairDebt(id, token0, token1, debtChange0, debtChange1);
        } else {
            // Limits the debt change to 128 bits
            if (msg.value > type(uint128).max) revert PaymentOverflow();

            if (token0 == NATIVE_TOKEN_ADDRESS) {
                unchecked {
                    // token0 is native, so we can still use pair update with adjusted debtChange0
                    // Subtraction is safe because debtChange0 and msg.value are both bounded by int128/uint128
                    _updatePairDebt(id, token0, token1, debtChange0 - int256(msg.value), debtChange1);
                }
            } else {
                // token0 is not native, and since token0 < token1, token1 cannot be native either
                // Update the token0, token1 debt and then update native token debt separately
                unchecked {
                    _updatePairDebt(id, token0, token1, debtChange0, debtChange1);
                    _accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
                }
            }
        }
    }

    /// @inheritdoc ICore
    function updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        positionId.validateBounds(poolKey.tickSpacing());

        (uint256 id, address lockerAddr) = _requireLocker().parse();

        IExtension(poolKey.extension()).maybeCallBeforeUpdatePosition(lockerAddr, poolKey, positionId, liquidityDelta);

        PoolId poolId = poolKey.toPoolId();
        PoolState state = readPoolState(poolId);
        if (!state.isInitialized()) revert PoolNotInitialized();

        if (liquidityDelta != 0) {
            (SqrtRatio sqrtRatioLower, SqrtRatio sqrtRatioUpper) =
                (tickToSqrtRatio(positionId.tickLower()), tickToSqrtRatio(positionId.tickUpper()));

            (delta0, delta1) =
                liquidityDeltaToAmountDelta(state.sqrtRatio(), liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

            bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, lockerAddr, positionId);
            Position storage position;
            assembly ("memory-safe") {
                position.slot := positionSlot
            }

            FeesPerLiquidity memory feesPerLiquidityInside = _getPoolFeesPerLiquidityInside(
                poolId, positionId.tickLower(), positionId.tickUpper(), poolKey.tickSpacing()
            );

            (uint128 fees0, uint128 fees1) = position.fees(feesPerLiquidityInside);

            uint128 liquidityNext = addLiquidityDelta(position.liquidity, liquidityDelta);

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
                _updateTick(poolId, positionId.tickLower(), poolKey.tickSpacing(), liquidityDelta, false);
                _updateTick(poolId, positionId.tickUpper(), poolKey.tickSpacing(), liquidityDelta, true);

                if (state.tick() >= positionId.tickLower() && state.tick() < positionId.tickUpper()) {
                    state = createPoolState({
                        _sqrtRatio: state.sqrtRatio(),
                        _tick: state.tick(),
                        _liquidity: addLiquidityDelta(state.liquidity(), liquidityDelta)
                    });
                    writePoolState(poolId, state);
                }
            } else {
                state = createPoolState({
                    _sqrtRatio: state.sqrtRatio(),
                    _tick: state.tick(),
                    _liquidity: addLiquidityDelta(state.liquidity(), liquidityDelta)
                });
                writePoolState(poolId, state);
            }

            _updatePairDebtWithNative(id, poolKey.token0, poolKey.token1, delta0, delta1);

            emit PositionUpdated(lockerAddr, poolId, positionId, liquidityDelta, delta0, delta1, state);
        }

        IExtension(poolKey.extension()).maybeCallAfterUpdatePosition(
            lockerAddr, poolKey, positionId, liquidityDelta, delta0, delta1, state
        );
    }

    /// @inheritdoc ICore
    function collectFees(PoolKey memory poolKey, PositionId positionId)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (uint256 id, address lockerAddr) = _requireLocker().parse();

        IExtension(poolKey.extension()).maybeCallBeforeCollectFees(lockerAddr, poolKey, positionId);

        PoolId poolId = poolKey.toPoolId();

        Position storage position;
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, lockerAddr, positionId);
        assembly ("memory-safe") {
            position.slot := positionSlot
        }

        FeesPerLiquidity memory feesPerLiquidityInside = _getPoolFeesPerLiquidityInside(
            poolId, positionId.tickLower(), positionId.tickUpper(), poolKey.tickSpacing()
        );

        (amount0, amount1) = position.fees(feesPerLiquidityInside);

        position.feesPerLiquidityInsideLast = feesPerLiquidityInside;

        _updatePairDebt(id, poolKey.token0, poolKey.token1, -int256(uint256(amount0)), -int256(uint256(amount1)));

        emit PositionFeesCollected(lockerAddr, poolId, positionId, amount0, amount1);

        IExtension(poolKey.extension()).maybeCallAfterCollectFees(lockerAddr, poolKey, positionId, amount0, amount1);
    }

    /// @inheritdoc ICore
    function swap_611415377(
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external payable returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        unchecked {
            if (!sqrtRatioLimit.isValid()) revert InvalidSqrtRatioLimit();

            Locker locker = _requireLocker();

            IExtension(poolKey.extension()).maybeCallBeforeSwap(
                locker.addr(), poolKey, amount, isToken1, sqrtRatioLimit, skipAhead
            );

            PoolId poolId = poolKey.toPoolId();

            (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = readPoolState(poolId).parse();

            if (sqrtRatio.isZero()) revert PoolNotInitialized();

            // 0 swap amount or sqrt ratio limit == sqrt ratio is no-op
            if (amount != 0 && sqrtRatio != sqrtRatioLimit) {
                bool increasing = isPriceIncreasing(amount, isToken1);
                if ((sqrtRatioLimit < sqrtRatio) == increasing) {
                    revert SqrtRatioLimitWrongDirection();
                }
                bool isExactOut = amount < 0;

                int128 amountRemaining = amount;
                uint256 calculatedAmount;

                // the slot where inputTokenFeesPerLiquidity is stored, reused later
                bytes32 inputTokenFeesPerLiquiditySlot;

                // fees per liquidity only for the input token
                uint256 inputTokenFeesPerLiquidity;

                // this loads only the input token fees per liquidity
                if (poolKey.mustLoadFees()) {
                    bytes32 fplSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
                    assembly ("memory-safe") {
                        inputTokenFeesPerLiquiditySlot := add(fplSlot, increasing)
                        inputTokenFeesPerLiquidity := sload(inputTokenFeesPerLiquiditySlot)
                    }
                }

                while (true) {
                    int32 nextTick;
                    bool isInitialized;
                    SqrtRatio nextTickSqrtRatio;

                    if (poolKey.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) {
                        (nextTick, isInitialized) = increasing
                            ? findNextInitializedTick(
                                CoreStorageLayout.tickBitmapsSlot(poolId), tick, poolKey.tickSpacing(), skipAhead
                            )
                            : findPrevInitializedTick(
                                CoreStorageLayout.tickBitmapsSlot(poolId), tick, poolKey.tickSpacing(), skipAhead
                            );

                        nextTickSqrtRatio = tickToSqrtRatio(nextTick);
                    } else {
                        // we never cross ticks in the full range version
                        (nextTick, nextTickSqrtRatio) =
                            increasing ? (MAX_TICK, MAX_SQRT_RATIO) : (MIN_TICK, MIN_SQRT_RATIO);
                    }

                    SqrtRatio limitedNextSqrtRatio =
                        increasing ? nextTickSqrtRatio.min(sqrtRatioLimit) : nextTickSqrtRatio.max(sqrtRatioLimit);

                    SqrtRatio sqrtRatioNext;

                    if (liquidity == 0) {
                        // if the pool is empty, the swap will always move all the way to the limit price
                        sqrtRatioNext = limitedNextSqrtRatio;
                    } else {
                        // this amount is what moves the price
                        int128 priceImpactAmount;
                        if (isExactOut) {
                            priceImpactAmount = amountRemaining;
                        } else {
                            // cast is safe because amount is g.t.e. 0
                            // then cast back to int128 is also safe because computeFee never returns a value g.t. the input amount
                            priceImpactAmount =
                                amountRemaining - int128(computeFee(uint128(amountRemaining), poolKey.fee()));
                        }

                        SqrtRatio sqrtRatioNextFromAmount = isToken1
                            ? nextSqrtRatioFromAmount1(sqrtRatio, liquidity, priceImpactAmount)
                            : nextSqrtRatioFromAmount0(sqrtRatio, liquidity, priceImpactAmount);

                        bool hitLimit;
                        assembly ("memory-safe") {
                            // Branchless limit check: (increasing && next > limit) || (!increasing && next < limit)
                            let exceedsUp := and(increasing, gt(sqrtRatioNextFromAmount, limitedNextSqrtRatio))
                            let exceedsDown :=
                                and(iszero(increasing), lt(sqrtRatioNextFromAmount, limitedNextSqrtRatio))
                            hitLimit := or(exceedsUp, exceedsDown)
                        }

                        uint128 feeAmount;

                        if (hitLimit) {
                            (uint128 specifiedAmountDelta, uint128 calculatedAmountDelta) = isToken1
                                ? (
                                    amount1Delta(limitedNextSqrtRatio, sqrtRatio, liquidity, !isExactOut),
                                    amount0Delta(limitedNextSqrtRatio, sqrtRatio, liquidity, isExactOut)
                                )
                                : (
                                    amount0Delta(limitedNextSqrtRatio, sqrtRatio, liquidity, !isExactOut),
                                    amount1Delta(limitedNextSqrtRatio, sqrtRatio, liquidity, isExactOut)
                                );

                            if (isExactOut) {
                                uint128 beforeFee = amountBeforeFee(calculatedAmountDelta, poolKey.fee());
                                amountRemaining += SafeCastLib.toInt128(specifiedAmountDelta);
                                calculatedAmount += beforeFee;
                                feeAmount = beforeFee - calculatedAmountDelta;
                            } else {
                                uint128 beforeFee = amountBeforeFee(specifiedAmountDelta, poolKey.fee());
                                amountRemaining -= SafeCastLib.toInt128(beforeFee);
                                calculatedAmount += calculatedAmountDelta;
                                feeAmount = beforeFee - specifiedAmountDelta;
                            }

                            sqrtRatioNext = limitedNextSqrtRatio;
                        } else if (sqrtRatioNextFromAmount == sqrtRatio) {
                            // for an exact output swap, the price should always move because we have to round away from the current price
                            // or else the pool can leak value
                            assert(!isExactOut);

                            amountRemaining = 0;
                            sqrtRatioNext = sqrtRatio;
                            // consume the entire input amount as fees since the price did not move
                            feeAmount = uint128(amountRemaining);

                            sqrtRatioNext = sqrtRatioNextFromAmount;
                        } else {
                            uint128 calculatedAmountWithoutFee = isToken1
                                ? amount0Delta(sqrtRatioNextFromAmount, sqrtRatio, liquidity, isExactOut)
                                : amount1Delta(sqrtRatioNextFromAmount, sqrtRatio, liquidity, isExactOut);

                            if (isExactOut) {
                                uint128 includingFee = amountBeforeFee(calculatedAmountWithoutFee, poolKey.fee());
                                calculatedAmount += includingFee;
                                feeAmount = includingFee - calculatedAmountWithoutFee;
                            } else {
                                calculatedAmount += calculatedAmountWithoutFee;
                                feeAmount = uint128(amountRemaining - priceImpactAmount);
                            }

                            amountRemaining = 0;
                            sqrtRatioNext = sqrtRatioNextFromAmount;
                        }

                        // this accounts the fees into the feesPerLiquidity memory struct
                        assembly ("memory-safe") {
                            // div by 0 returns 0, so it's ok
                            let v := div(shl(128, feeAmount), liquidity)
                            inputTokenFeesPerLiquidity := add(inputTokenFeesPerLiquidity, v)
                        }
                    }

                    if (sqrtRatioNext == nextTickSqrtRatio) {
                        sqrtRatio = sqrtRatioNext;
                        assembly ("memory-safe") {
                            // no overflow danger because nextTick is always inside the valid tick bounds
                            tick := sub(nextTick, iszero(increasing))
                        }

                        if (isInitialized) {
                            int128 liquidityDelta;
                            bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, nextTick);
                            assembly ("memory-safe") {
                                liquidityDelta := signextend(15, sload(tickSlot))
                            }

                            liquidity = increasing
                                ? addLiquidityDelta(liquidity, liquidityDelta)
                                : subLiquidityDelta(liquidity, liquidityDelta);

                            FeesPerLiquidity memory tickFpl;
                            (bytes32 tickFplFirstSlot, bytes32 tickFplSecondSlot) =
                                CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, nextTick);
                            assembly ("memory-safe") {
                                mstore(tickFpl, sload(tickFplFirstSlot))
                                mstore(add(tickFpl, 0x20), sload(tickFplSecondSlot))
                            }

                            FeesPerLiquidity memory totalFpl;

                            // load only the slot we didn't load before into totalFpl
                            assembly ("memory-safe") {
                                mstore(add(totalFpl, mul(32, increasing)), inputTokenFeesPerLiquidity)

                                let outputTokenFeesPerLiquidity :=
                                    sload(add(sub(inputTokenFeesPerLiquiditySlot, increasing), iszero(increasing)))
                                mstore(add(totalFpl, mul(32, iszero(increasing))), outputTokenFeesPerLiquidity)
                            }

                            totalFpl.subAssign(tickFpl);
                            assembly ("memory-safe") {
                                sstore(tickFplFirstSlot, mload(totalFpl))
                                sstore(tickFplSecondSlot, mload(add(totalFpl, 0x20)))
                            }
                        }
                    } else if (sqrtRatio != sqrtRatioNext) {
                        sqrtRatio = sqrtRatioNext;
                        tick = sqrtRatioToTick(sqrtRatio);
                    }

                    if (amountRemaining == 0 || sqrtRatio == sqrtRatioLimit) {
                        break;
                    }
                }

                int256 calculatedAmountSign = int256(FixedPointMathLib.ternary(isExactOut, 1, type(uint256).max));
                int128 calculatedAmountDelta = SafeCastLib.toInt128(
                    FixedPointMathLib.max(type(int128).min, calculatedAmountSign * int256(calculatedAmount))
                );

                (delta0, delta1) = isToken1
                    ? (calculatedAmountDelta, amount - amountRemaining)
                    : (amount - amountRemaining, calculatedAmountDelta);

                stateAfter = createPoolState({_sqrtRatio: sqrtRatio, _tick: tick, _liquidity: liquidity});

                assembly ("memory-safe") {
                    sstore(poolId, stateAfter)
                }

                if (poolKey.mustLoadFees()) {
                    assembly ("memory-safe") {
                        // this stores only the input token fees per liquidity
                        sstore(inputTokenFeesPerLiquiditySlot, inputTokenFeesPerLiquidity)
                    }
                }

                _updatePairDebtWithNative(locker.id(), poolKey.token0, poolKey.token1, delta0, delta1);

                assembly ("memory-safe") {
                    let o := mload(0x40)
                    mstore(o, shl(96, locker))
                    mstore(add(o, 20), poolId)
                    mstore(add(o, 52), or(shl(128, delta0), and(delta1, 0xffffffffffffffffffffffffffffffff)))
                    mstore(add(o, 84), stateAfter)
                    log0(o, 116)
                }
            }

            IExtension(poolKey.extension()).maybeCallAfterSwap(
                locker.addr(), poolKey, amount, isToken1, sqrtRatioLimit, skipAhead, delta0, delta1, stateAfter
            );
        }
    }
}
