// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {Locker} from "./types/locker.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionId} from "./types/positionId.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "./types/feesPerLiquidity.sol";
import {isPriceIncreasing, SqrtRatioLimitWrongDirection, SwapResult, swapResult} from "./math/swap.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "./math/ticks.sol";
import {Bitmap} from "./types/bitmap.sol";
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

/// @title Ekubo Protocol Core
/// @author Moody Salem <moody@ekubo.org>
/// @notice Singleton contract holding all tokens and containing all possible operations in Ekubo Protocol
/// @dev Implements the core AMM functionality including pools, positions, swaps, and fee collection
contract Core is ICore, FlashAccountant, ExposedStorage {
    using {findNextInitializedTick, findPrevInitializedTick, flipTick} for mapping(uint256 word => Bitmap bitmap);
    using ExtensionCallPointsLib for *;

    /// @notice Mapping of extension addresses to their registration status
    mapping(address extension => bool isRegistered) private isExtensionRegistered;

    /// @notice Mapping of pool IDs to their accumulated fees per liquidity
    mapping(bytes32 poolId => FeesPerLiquidity feesPerLiquidity) private poolFeesPerLiquidity;
    /// @notice Mapping of pool IDs to position IDs to position data
    mapping(bytes32 poolId => mapping(address owner => mapping(PositionId positionId => Position position))) private
        poolPositions;
    /// @notice Mapping of pool IDs to tick information
    mapping(bytes32 poolId => mapping(int32 tick => TickInfo tickInfo)) private poolTicks;
    /// @notice Mapping of pool IDs to tick fees per liquidity outside the tick
    mapping(bytes32 poolId => mapping(int32 tick => FeesPerLiquidity feesPerLiquidityOutside)) private
        poolTickFeesPerLiquidityOutside;
    /// @notice Mapping of pool IDs to initialized tick bitmaps
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) private poolInitializedTickBitmaps;

    /// @inheritdoc ICore
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) {
            revert FailedRegisterInvalidCallPoints();
        }
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;
        emit ExtensionRegistered(msg.sender);
    }

    function readPoolState(bytes32 poolId) internal view returns (PoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function writePoolState(bytes32 poolId, PoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }

    /// @inheritdoc ICore
    function initializePool(PoolKey memory poolKey, int32 tick) external returns (SqrtRatio sqrtRatio) {
        poolKey.validatePoolKey();

        address extension = poolKey.extension();
        if (extension != address(0)) {
            if (!isExtensionRegistered[extension]) {
                revert ExtensionNotRegistered();
            }

            IExtension(extension).maybeCallBeforeInitializePool(msg.sender, poolKey, tick);
        }

        bytes32 poolId = poolKey.toPoolId();
        PoolState state = readPoolState(poolId);
        if (state.isInitialized()) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        writePoolState(poolId, createPoolState({_sqrtRatio: sqrtRatio, _tick: tick, _liquidity: 0}));

        emit PoolInitialized(poolId, poolKey, tick, sqrtRatio);

        IExtension(extension).maybeCallAfterInitializePool(msg.sender, poolKey, tick, sqrtRatio);
    }

    /// @inheritdoc ICore
    function prevInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            poolInitializedTickBitmaps[poolId].findPrevInitializedTick(fromTick, tickSpacing, skipAhead);
    }

    /// @inheritdoc ICore
    function nextInitializedTick(bytes32 poolId, int32 fromTick, uint32 tickSpacing, uint256 skipAhead)
        external
        view
        returns (int32 tick, bool isInitialized)
    {
        (tick, isInitialized) =
            poolInitializedTickBitmaps[poolId].findNextInitializedTick(fromTick, tickSpacing, skipAhead);
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

        Locker locker = _requireLocker();
        (uint256 id, address lockerAddr) = locker.parse();

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
    function _getPoolFeesPerLiquidityInside(bytes32 poolId, int32 tickLower, int32 tickUpper, uint32 tickSpacing)
        internal
        view
        returns (FeesPerLiquidity memory)
    {
        if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) return poolFeesPerLiquidity[poolId];

        int32 tick = readPoolState(poolId).tick();
        mapping(int32 => FeesPerLiquidity) storage poolIdEntry = poolTickFeesPerLiquidityOutside[poolId];
        FeesPerLiquidity memory lower = poolIdEntry[tickLower];
        FeesPerLiquidity memory upper = poolIdEntry[tickUpper];

        if (tick < tickLower) {
            lower.subAssign(upper);
            return lower;
        } else if (tick < tickUpper) {
            FeesPerLiquidity memory fees = poolFeesPerLiquidity[poolId];

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
        Locker locker = _requireLocker();
        (uint256 id, address lockerAddr) = locker.parse();
        require(lockerAddr == poolKey.extension());

        bytes32 poolId = poolKey.toPoolId();

        // Note we do not check pool is initialized. If the extension calls this for a pool that does not exist,
        //  the fees are simply burned since liquidity is 0.

        assembly ("memory-safe") {
            if or(amount0, amount1) {
                let liquidity := shr(128, shl(128, sload(poolId)))

                if liquidity {
                    mstore(0, poolId)
                    mstore(32, 1)
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
    function _updateTick(bytes32 poolId, int32 tick, uint32 tickSpacing, int128 liquidityDelta, bool isUpper) private {
        bytes32 slot;
        TickInfo ti;

        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 3)
            mstore(32, keccak256(0, 64))
            mstore(0, tick)
            slot := keccak256(0, 64)
            ti := sload(slot)
        }

        (int128 currentLiquidityDelta, uint128 currentLiquidityNet) = ti.parse();
        uint128 liquidityNetNext = addLiquidityDelta(currentLiquidityNet, liquidityDelta);
        // this is checked math
        int128 liquidityDeltaNext =
            isUpper ? currentLiquidityDelta - liquidityDelta : currentLiquidityDelta + liquidityDelta;

        if ((currentLiquidityNet == 0) != (liquidityNetNext == 0)) {
            flipTick(poolInitializedTickBitmaps[poolId], tick, tickSpacing);
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
        Locker locker = _requireLocker();
        (uint256 id, address lockerAddr) = locker.parse();

        address extension = poolKey.extension();
        IExtension(extension).maybeCallBeforeUpdatePosition(lockerAddr, poolKey, positionId, liquidityDelta);

        positionId.validateBounds(poolKey.tickSpacing());

        if (liquidityDelta != 0) {
            bytes32 poolId = poolKey.toPoolId();
            PoolState state = readPoolState(poolId);
            if (!state.isInitialized()) revert PoolNotInitialized();

            (SqrtRatio sqrtRatioLower, SqrtRatio sqrtRatioUpper) =
                (tickToSqrtRatio(positionId.tickLower()), tickToSqrtRatio(positionId.tickUpper()));

            (delta0, delta1) =
                liquidityDeltaToAmountDelta(state.sqrtRatio(), liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

            Position storage position = poolPositions[poolId][lockerAddr][positionId];

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
                    writePoolState(
                        poolId,
                        createPoolState({
                            _sqrtRatio: state.sqrtRatio(),
                            _tick: state.tick(),
                            _liquidity: addLiquidityDelta(state.liquidity(), liquidityDelta)
                        })
                    );
                }
            } else {
                writePoolState(
                    poolId,
                    createPoolState({
                        _sqrtRatio: state.sqrtRatio(),
                        _tick: state.tick(),
                        _liquidity: addLiquidityDelta(state.liquidity(), liquidityDelta)
                    })
                );
            }

            _updatePairDebtWithNative(id, poolKey.token0, poolKey.token1, delta0, delta1);

            emit PositionUpdated(lockerAddr, poolId, positionId, liquidityDelta, delta0, delta1);
        }

        IExtension(extension).maybeCallAfterUpdatePosition(
            lockerAddr, poolKey, positionId, liquidityDelta, delta0, delta1
        );
    }

    /// @inheritdoc ICore
    function collectFees(PoolKey memory poolKey, PositionId positionId)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        Locker locker = _requireLocker();
        (uint256 id, address lockerAddr) = locker.parse();

        address extension = poolKey.extension();
        IExtension(extension).maybeCallBeforeCollectFees(lockerAddr, poolKey, positionId);

        bytes32 poolId = poolKey.toPoolId();

        Position memory position = poolPositions[poolId][lockerAddr][positionId];

        FeesPerLiquidity memory feesPerLiquidityInside = _getPoolFeesPerLiquidityInside(
            poolId, positionId.tickLower(), positionId.tickUpper(), poolKey.tickSpacing()
        );

        (amount0, amount1) = position.fees(feesPerLiquidityInside);

        poolPositions[poolId][lockerAddr][positionId] =
            Position({liquidity: position.liquidity, feesPerLiquidityInsideLast: feesPerLiquidityInside});

        _updatePairDebt(id, poolKey.token0, poolKey.token1, -int256(uint256(amount0)), -int256(uint256(amount1)));

        emit PositionFeesCollected(lockerAddr, poolId, positionId, amount0, amount1);

        IExtension(extension).maybeCallAfterCollectFees(lockerAddr, poolKey, positionId, amount0, amount1);
    }

    /// @inheritdoc ICore
    function swap_611415377(
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external payable returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        if (!sqrtRatioLimit.isValid()) revert InvalidSqrtRatioLimit();

        Locker locker = _requireLocker();
        (uint256 id, address lockerAddr) = locker.parse();

        address extension = poolKey.extension();
        IExtension(extension).maybeCallBeforeSwap(lockerAddr, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

        bytes32 poolId = poolKey.toPoolId();

        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = readPoolState(poolId).parse();

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
                    mstore(32, 1)
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

                unchecked {
                    // the signs are the same and a swap round can't consume more than it was given
                    amountRemaining -= result.consumedAmount;
                }
                calculatedAmount += result.calculatedAmount;

                if (result.sqrtRatioNext == nextTickSqrtRatio) {
                    sqrtRatio = result.sqrtRatioNext;
                    assembly ("memory-safe") {
                        // no overflow danger because nextTick is always inside the valid tick bounds
                        tick := sub(nextTick, iszero(increasing))
                    }

                    if (isInitialized) {
                        int128 liquidityDelta = poolTicks[poolId][nextTick].liquidityDelta();
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

            _updatePairDebtWithNative(id, poolKey.token0, poolKey.token1, delta0, delta1);

            assembly ("memory-safe") {
                let o := mload(0x40)
                mstore(o, shl(96, lockerAddr))
                mstore(add(o, 20), poolId)
                mstore(add(o, 52), or(shl(128, delta0), and(delta1, 0xffffffffffffffffffffffffffffffff)))
                mstore(add(o, 84), stateAfter)
                log0(o, 116)
            }
        }

        IExtension(extension).maybeCallAfterSwap(
            lockerAddr, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead, delta0, delta1
        );
    }
}
