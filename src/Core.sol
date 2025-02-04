// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionKey, Bounds} from "./types/positionKey.sol";
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
import {liquidityDeltaToAmountDelta, addLiquidityDelta, subLiquidityDelta} from "./math/liquidity.sol";
import {computeFee} from "./math/fee.sol";
import {findNextInitializedTick, findPrevInitializedTick, flipTick} from "./math/tickBitmap.sol";
import {ICore, UpdatePositionParameters, SwapParameters, IExtension} from "./interfaces/ICore.sol";
import {NATIVE_TOKEN_ADDRESS} from "./interfaces/IFlashAccountant.sol";
import {FlashAccountant} from "./base/FlashAccountant.sol";

contract Core is ICore, FlashAccountant, Ownable, ExposedStorage {
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

    constructor(address owner) {
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
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;
        emit ExtensionRegistered(msg.sender);
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

        emit PoolInitialized(poolId, poolKey, tick, sqrtRatio);

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

    function load(address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = _getLocker();

        unchecked {
            uint256 balance = savedBalances[msg.sender][token][salt];
            if (balance < amount) {
                revert InsufficientSavedBalance();
            }

            // safe because we reverted if balance < amount
            savedBalances[msg.sender][token][salt] = balance - amount;

            _accountDebt(id, token, -int256(uint256(amount)));
        }

        emit LoadedBalance(msg.sender, token, salt, amount);
    }

    function save(address owner, address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = _requireLocker();

        unchecked {
            // this is always safe because amount is a uint128 and savedBalances a uint256
            savedBalances[owner][token][salt] += amount;
            _accountDebt(id, token, int256(uint256(amount)));
        }

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
        (uint256 id, address locker) = _requireLocker();
        require(locker == poolKey.extension);

        bytes32 poolId = poolKey.toPoolId();

        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 3)
            let liquidity := sload(keccak256(0, 64))

            if or(amount0, amount1) {
                mstore(0, poolId)
                mstore(32, 4)
                let slot0 := keccak256(0, 64)

                if amount0 {
                    let v := div(shl(128, amount0), liquidity)
                    sstore(slot0, add(sload(slot0), v))
                }
                if amount1 {
                    let v := div(shl(128, amount1), liquidity)
                    sstore(add(slot0, 1), add(sload(add(slot0, 1)), v))
                }
            }
        }

        _accountDebt(id, poolKey.token0, int256(uint256(amount0)));
        _accountDebt(id, poolKey.token1, int256(uint256(amount1)));

        emit FeesAccumulated(poolId, amount0, amount1);
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
        (uint256 id, address locker) = _requireLocker();

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
                        uint128 protocolFees0 = computeFee(uint128(-delta0), poolKey.fee);
                        uint128 protocolFees1 = computeFee(uint128(-delta1), poolKey.fee);

                        if (protocolFees0 > 0) {
                            // this will never overflow for a well behaved token since protocol fees are stored as uint256
                            protocolFeesCollected[poolKey.token0] += protocolFees0;

                            // protocolFees0 is at most equal to delta0, so this will maximally reach 0 and no overflow/underflow check is needed
                            // in addition, casting is safe because computed fee is never g.t. the input amount, which is an int128
                            delta0 += int128(protocolFees0);
                        }

                        // same reasoning applies for the unchecked safety here
                        if (protocolFees1 > 0) {
                            protocolFeesCollected[poolKey.token1] += protocolFees1;
                            delta1 += int128(protocolFees1);
                        }
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

            _accountDebt(id, poolKey.token0, delta0);
            _accountDebt(id, poolKey.token1, delta1);

            emit PositionUpdated(locker, poolId, params, delta0, delta1);
        }

        if (shouldCallAfterUpdatePosition(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterUpdatePosition(locker, poolKey, params, delta0, delta1);
        }
    }

    function collectFees(PoolKey memory poolKey, bytes32 salt, Bounds memory bounds)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (uint256 id, address locker) = _requireLocker();

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

        _accountDebt(id, poolKey.token0, -int256(uint256(amount0)));
        _accountDebt(id, poolKey.token1, -int256(uint256(amount1)));

        emit PositionFeesCollected(poolId, positionKey, amount0, amount1);

        if (shouldCallAfterCollectFees(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterCollectFees(locker, poolKey, salt, bounds, amount0, amount1);
        }
    }

    function swap(PoolKey memory poolKey, SwapParameters memory params)
        external
        returns (int128 delta0, int128 delta1)
    {
        (uint256 id, address locker) = _requireLocker();

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
            bool hasCrossed;
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

            // the slot where inputTokenFeesPerLiquidity is stored, reused later
            bytes32 inputTokenFeesPerLiquiditySlot;

            // fees per liquidity only for the input token
            uint256 inputTokenFeesPerLiquidity;

            // this loads only the input token fees per liquidity
            assembly ("memory-safe") {
                mstore(0, poolId)
                mstore(32, 4)
                inputTokenFeesPerLiquiditySlot := add(keccak256(0, 64), increasing)
                inputTokenFeesPerLiquidity := sload(inputTokenFeesPerLiquiditySlot)
            }

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
                    inputTokenFeesPerLiquidity := add(inputTokenFeesPerLiquidity, v)
                }

                amountRemaining -= result.consumedAmount;
                calculatedAmount += result.calculatedAmount;

                if (result.sqrtRatioNext == nextTickSqrtRatio) {
                    sqrtRatio = result.sqrtRatioNext;
                    tick = increasing ? nextTick : nextTick - 1;

                    if (isInitialized) {
                        hasCrossed = true;
                        int128 liquidityDelta = ticks[nextTick].liquidityDelta;
                        liquidity = increasing
                            ? addLiquidityDelta(liquidity, liquidityDelta)
                            : subLiquidityDelta(liquidity, liquidityDelta);
                        FeesPerLiquidity memory tickFpl = tickFeesPerLiquidityOutside[nextTick];

                        FeesPerLiquidity memory totalFpl;

                        // load only the slot we didn't load before into totalFpl
                        assembly ("memory-safe") {
                            mstore(add(totalFpl, mul(32, increasing)), inputTokenFeesPerLiquidity)

                            let outputTokenFeesPerLiquidity :=
                                sload(add(sub(inputTokenFeesPerLiquiditySlot, increasing), iszero(increasing)))
                            mstore(add(totalFpl, mul(32, iszero(increasing))), outputTokenFeesPerLiquidity)
                        }

                        tickFeesPerLiquidityOutside[nextTick] = totalFpl.sub(tickFpl);
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

            assembly ("memory-safe") {
                mstore(0, poolId)
                mstore(32, 2)
                sstore(keccak256(0, 64), or(shl(192, tick), sqrtRatio))

                if hasCrossed {
                    mstore(0, poolId)
                    mstore(32, 3)
                    sstore(keccak256(0, 64), liquidity)
                }

                // this stores only the input token fees per liquidity
                sstore(inputTokenFeesPerLiquiditySlot, inputTokenFeesPerLiquidity)
            }

            _accountDebt(id, poolKey.token0, delta0);
            _accountDebt(id, poolKey.token1, delta1);

            assembly ("memory-safe") {
                let o := mload(0x40)
                mstore(o, locker)
                mstore(add(o, 32), poolId)
                mstore(add(o, 64), add(shl(128, delta0), delta1))
                // upper 128 bits are 0, overwritten by next mstore
                mstore(add(o, 112), liquidity)
                mstore(add(o, 96), add(shl(160, tick), sqrtRatio))
                log0(o, 144)
            }
        }

        if (shouldCallAfterSwap(poolKey.extension) && locker != poolKey.extension) {
            IExtension(poolKey.extension).afterSwap(locker, poolKey, params, delta0, delta1);
        }
    }
}
