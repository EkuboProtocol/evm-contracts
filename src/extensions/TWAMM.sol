// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, toConfig} from "../types/poolKey.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../types/sqrtRatio.sol";
import {ILocker} from "../interfaces/IFlashAccountant.sol";
import {ICore, UpdatePositionParameters} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {Bitmap} from "../math/bitmap.sol";
import {searchForNextInitializedTime, flipTime} from "../math/timeBitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {computeFee} from "../math/fee.sol";
import {
    computeNextSqrtRatio, computeAmountFromSaleRate, computeRewardAmount, addSaleRateDelta
} from "../math/twamm.sol";
import {isTimeValid, MAX_ABS_VALUE_SALE_RATE_DELTA} from "../math/time.sol";

function twammCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: true,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

using {toOrderId} for OrderKey global;

struct OrderKey {
    address sellToken;
    address buyToken;
    // todo: these could take up as few as 32+64+64=160 bits
    uint64 fee;
    uint256 startTime;
    uint256 endTime;
}

function toOrderId(OrderKey memory orderKey) pure returns (bytes32 id) {
    assembly ("memory-safe") {
        id := keccak256(orderKey, 160)
    }
}

struct UpdateSaleRateParams {
    bytes32 salt;
    OrderKey orderKey;
    int112 saleRateDelta;
}

struct CollectProceedsParams {
    bytes32 salt;
    OrderKey orderKey;
}

contract TWAMM is ExposedStorage, BaseExtension, BaseForwardee, ILocker {
    using {searchForNextInitializedTime, flipTime} for mapping(uint256 word => Bitmap bitmap);
    using CoreLib for *;

    event OrderUpdated(address owner, bytes32 salt, OrderKey orderKey, int112 saleRateDelta);
    event OrderProceedsWithdrawn(address owner, bytes32 salt, OrderKey orderKey, uint128 amount);

    error TimeNumOrdersOverflow();
    error TickSpacingMustBeMaximum();
    error OrderAlreadyEnded();
    error InvalidTimestamps();
    error MustCollectProceedsBeforeCanceling();
    error MaxSaleRateDeltaPerTime();
    error PoolNotInitialized();

    struct PoolState {
        uint32 lastVirtualOrderExecutionTime;
        // 80.32 numbers, meaning the maximum amount of either token sold per second is 1.2089258196E24
        uint112 saleRateToken0;
        uint112 saleRateToken1;
    }

    struct OrderState {
        // the current sale rate of the order
        uint112 saleRate;
        // reward rate for the order range at the last time it was touched
        uint256 rewardRateSnapshot;
    }

    struct TimeInfo {
        // the number of orders referencing this timestamp. If non-zero, then the time is initialized.
        uint32 numOrders;
        // the change of sale rate for token0 at this time
        int112 saleRateDeltaToken0;
        // the change of sale rate for token1 at this time
        int112 saleRateDeltaToken1;
    }

    mapping(bytes32 poolId => PoolState) internal poolState;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) internal poolInitializedTimesBitmap;
    mapping(bytes32 poolId => mapping(uint256 time => TimeInfo)) internal poolTimeInfos;

    // The global reward rate and the reward rate before a given time are both used to
    mapping(bytes32 poolId => FeesPerLiquidity) internal poolRewardRates;
    mapping(bytes32 poolId => mapping(uint256 time => FeesPerLiquidity)) internal poolRewardRatesBefore;

    // Current state of each individual order
    mapping(address owner => mapping(bytes32 salt => mapping(bytes32 orderId => OrderState))) internal orderState;

    // Auxiliary mapping that just indicates whether a pool is indeed initialized
    // This is only checked in the case that lastVirtualOrderExecutionTime is zero
    mapping(bytes32 poolId => bool) poolInitialized;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function _emitVirtualOrdersExecuted(bytes32 poolId, uint112 saleRateToken0, uint112 saleRateToken1) internal {
        assembly ("memory-safe") {
            // by writing it backwards, we overwrite only the empty bits with each subsequent write
            mstore(28, saleRateToken1)
            mstore(14, saleRateToken0)
            mstore(0, poolId)

            log0(0, 60)
        }
    }

    // Must be called on a pool that is executed up to the current timestamp
    function _getOrderInfo(address owner, bytes32 salt, OrderKey memory orderKey)
        internal
        view
        returns (uint112 saleRate, uint256 rewardRateInside, uint128 purchasedAmount)
    {
        OrderState memory order = orderState[owner][salt][orderKey.toOrderId()];

        unchecked {
            saleRate = order.saleRate;
            rewardRateInside = _getRewardRateInside(
                _orderKeyToPoolKey(orderKey).toPoolId(),
                orderKey.startTime,
                orderKey.endTime,
                orderKey.sellToken < orderKey.buyToken
            );

            purchasedAmount = computeRewardAmount(rewardRateInside - order.rewardRateSnapshot, saleRate);
        }
    }

    function _getRewardRateInside(bytes32 poolId, uint256 startTime, uint256 endTime, bool isToken1)
        internal
        view
        returns (uint256 result)
    {
        assembly ("memory-safe") {
            // if block.timestamp >= endTime
            switch lt(timestamp(), endTime)
            case 0 {
                mstore(0, poolId)
                mstore(32, 4)
                // hash poolId,4 and store at 32
                mstore(32, keccak256(0, 64))

                // now put start time at 0 for hashing
                mstore(0, startTime)

                let rewardRateStart := sload(add(keccak256(0, 64), isToken1))

                mstore(0, endTime)
                let rewardRateEnd := sload(add(keccak256(0, 64), isToken1))

                result := sub(rewardRateEnd, rewardRateStart)
            }
            default {
                // else if block.timestamp > startTime
                //  note that we check gt because if it's equal to start time, then the reward rate inside is necessarily 0
                switch gt(timestamp(), startTime)
                case 1 {
                    mstore(0, poolId)
                    mstore(32, 3)
                    let rewardRateCurrent := sload(add(keccak256(0, 64), isToken1))

                    mstore(32, 4)
                    // hash poolId,4 and store at 32
                    mstore(32, keccak256(0, 64))
                    // now put time at 0 for hashing
                    mstore(0, startTime)

                    result := sub(rewardRateCurrent, sload(add(keccak256(0, 64), isToken1)))
                }
                default {
                    // less than or equal to start time
                    // returns 0
                }
            }
        }
    }

    function _addConstrainSaleRateDelta(int112 saleRateDelta, int112 saleRateDeltaChange)
        internal
        pure
        returns (int112 saleRateDeltaNext)
    {
        unchecked {
            int256 result = int256(saleRateDelta) + saleRateDeltaChange;

            // checked addition, no overflow of int112 type
            if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
                revert MaxSaleRateDeltaPerTime();
            }

            // we know cast is safe because abs(result) is less than MAX_ABS_VALUE_SALE_RATE_DELTA which fits in a int112
            saleRateDeltaNext = int112(result);
        }
    }

    function _updateTime(bytes32 poolId, uint256 time, int112 saleRateDelta, bool isToken1, int256 numOrdersChange)
        internal
    {
        TimeInfo memory timeInfo = poolTimeInfos[poolId][time];

        bool flip;
        assembly ("memory-safe") {
            let numOrders := mload(timeInfo)
            // note we assume this will never overflow, since it would require 2**32 separate orders to be placed
            let numOrdersNext := add(numOrders, numOrdersChange)

            if gt(numOrdersNext, 0xffffffff) {
                mstore(0, shl(224, 0x6916a952))
                revert(0, 4)
            }

            flip := iszero(eq(iszero(numOrders), iszero(numOrdersNext)))

            mstore(timeInfo, numOrdersNext)
        }

        if (flip) {
            poolInitializedTimesBitmap[poolId].flipTime(uint32(time));
        }

        if (isToken1) {
            timeInfo.saleRateDeltaToken1 = _addConstrainSaleRateDelta(timeInfo.saleRateDeltaToken1, saleRateDelta);
        } else {
            timeInfo.saleRateDeltaToken0 = _addConstrainSaleRateDelta(timeInfo.saleRateDeltaToken0, saleRateDelta);
        }

        poolTimeInfos[poolId][time] = timeInfo;
    }

    function locked(uint256) external override onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            poolKey := mload(0x40)
            // points the free memory pointer at pointer + 96
            mstore(0x40, add(poolKey, 96))

            // copy the poolkey out of calldata at the free memory pointer
            calldatacopy(poolKey, 36, 96)
        }
        _executeVirtualOrdersFromWithinLock(poolKey);
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return twammCallPoints();
    }

    ///////////////////////// Callbacks /////////////////////////

    function handleForwardData(uint256, address originalLocker, bytes memory data)
        internal
        override
        returns (bytes memory result)
    {
        unchecked {
            uint256 callType = abi.decode(data, (uint256));

            if (callType == 0) {
                (, UpdateSaleRateParams memory params) = abi.decode(data, (uint256, UpdateSaleRateParams));

                if (params.orderKey.endTime <= block.timestamp) revert OrderAlreadyEnded();

                if (
                    !isTimeValid(block.timestamp, params.orderKey.startTime)
                        || !isTimeValid(block.timestamp, params.orderKey.endTime)
                        || params.orderKey.startTime >= params.orderKey.endTime
                ) {
                    revert InvalidTimestamps();
                }

                PoolKey memory poolKey = _orderKeyToPoolKey(params.orderKey);
                _executeVirtualOrdersFromWithinLock(poolKey);

                (uint112 saleRate, uint256 rewardRateSnapshot, uint128 purchasedAmount) =
                    _getOrderInfo(originalLocker, params.salt, params.orderKey);

                uint112 saleRateNext = addSaleRateDelta(saleRate, params.saleRateDelta);

                if (saleRateNext == 0 && purchasedAmount != 0) {
                    revert MustCollectProceedsBeforeCanceling();
                }

                uint256 rewardRateSnapshotAdjusted;
                int256 numOrdersChange;
                assembly ("memory-safe") {
                    rewardRateSnapshotAdjusted :=
                        mul(
                            sub(rewardRateSnapshot, div(shl(128, purchasedAmount), saleRateNext)),
                            // if saleRateNext is zero, write 0 for the reward rate snapshot adjusted
                            iszero(iszero(saleRateNext))
                        )

                    // if current is zero, and next is zero, then 1-1 = 0
                    // if current is nonzero, and next is nonzero, then 0-0 = 0
                    // if current is zero, and next is nonzero, then we get 1-0 = 1
                    // if current is nonzero, and next is zero, then we get 0-1 = -1 = (type(uint256).max)
                    numOrdersChange := sub(iszero(saleRate), iszero(saleRateNext))
                }

                orderState[originalLocker][params.salt][params.orderKey.toOrderId()] =
                    OrderState({saleRate: saleRateNext, rewardRateSnapshot: rewardRateSnapshotAdjusted});

                bool isToken1 = params.orderKey.sellToken > params.orderKey.buyToken;

                bytes32 poolId = poolKey.toPoolId();

                if (block.timestamp < params.orderKey.startTime) {
                    _updateTime(poolId, params.orderKey.startTime, params.saleRateDelta, isToken1, numOrdersChange);
                    _updateTime(poolId, params.orderKey.endTime, -params.saleRateDelta, isToken1, numOrdersChange);
                } else {
                    // we know block.timestamp < params.orderKey.endTime because we validate that first
                    // and we know the order is active, so we have to apply its delta to the current pool state
                    if (isToken1) {
                        poolState[poolId].saleRateToken1 =
                            addSaleRateDelta(poolState[poolId].saleRateToken1, params.saleRateDelta);
                    } else {
                        poolState[poolId].saleRateToken0 =
                            addSaleRateDelta(poolState[poolId].saleRateToken0, params.saleRateDelta);
                    }

                    // only update the end time
                    // todo: what if params.saleRateDelta is type(int112).min?
                    _updateTime(poolId, params.orderKey.endTime, -params.saleRateDelta, isToken1, numOrdersChange);
                }

                // we know this will fit in a uint32 because otherwise isValidTime would fail for the end time
                uint32 durationRemaining =
                    uint32(params.orderKey.endTime - FixedPointMathLib.max(block.timestamp, params.orderKey.startTime));

                // the amount required for executing at the next sale rate for the remaining duration of the order
                uint256 amountRequired =
                    computeAmountFromSaleRate({saleRate: saleRateNext, duration: durationRemaining, roundUp: true});

                // subtract the remaining sell amount to get the delta
                int256 amountDelta;

                uint256 remainingSellAmount = computeAmountFromSaleRate(saleRate, durationRemaining, true);

                assembly ("memory-safe") {
                    amountDelta := sub(amountRequired, remainingSellAmount)
                }

                // user is withdrawing tokens, so they need to pay a fee to the liquidity providers
                if (amountDelta < 0) {
                    // negation and downcast will never overflow, since max sale rate times max duration is at most type(uint112).max
                    uint128 amountAbs = uint128(uint256(-amountDelta));
                    uint128 fee = computeFee(amountAbs, poolKey.fee());
                    if (isToken1) {
                        core.accumulateAsFees(poolKey, 0, fee);
                        core.load(address(poolKey.token0), address(poolKey.token1), bytes32(0), 0, amountAbs);
                    } else {
                        core.accumulateAsFees(poolKey, fee, 0);
                        core.load(address(poolKey.token0), address(poolKey.token1), bytes32(0), amountAbs, 0);
                    }

                    amountDelta += int256(int128(fee));
                } else {
                    // downcast will never overflow, since max sale rate times max duration is at most type(uint112).max
                    uint128 amountAbs = uint128(uint256(amountDelta));

                    if (isToken1) {
                        core.save(
                            address(this), address(poolKey.token0), address(poolKey.token1), bytes32(0), 0, amountAbs
                        );
                    } else {
                        core.save(
                            address(this), address(poolKey.token0), address(poolKey.token1), bytes32(0), amountAbs, 0
                        );
                    }
                }

                emit OrderUpdated(originalLocker, params.salt, params.orderKey, params.saleRateDelta);

                result = abi.encode(amountDelta);
            } else if (callType == 1) {
                (, CollectProceedsParams memory params) = abi.decode(data, (uint256, CollectProceedsParams));

                PoolKey memory poolKey = _orderKeyToPoolKey(params.orderKey);
                _executeVirtualOrdersFromWithinLock(poolKey);

                (, uint256 rewardRateSnapshot, uint128 purchasedAmount) =
                    _getOrderInfo(originalLocker, params.salt, params.orderKey);

                orderState[originalLocker][params.salt][params.orderKey.toOrderId()].rewardRateSnapshot =
                    rewardRateSnapshot;

                if (purchasedAmount != 0) {
                    (uint128 amount0, uint128 amount1) = params.orderKey.sellToken > params.orderKey.buyToken
                        ? (purchasedAmount, uint128(0))
                        : (uint128(0), purchasedAmount);

                    core.load(poolKey.token0, poolKey.token1, bytes32(0), amount0, amount1);
                }

                emit OrderProceedsWithdrawn(originalLocker, params.salt, params.orderKey, purchasedAmount);

                result = abi.encode(purchasedAmount);
            } else {
                revert();
            }
        }
    }

    function _orderKeyToPoolKey(OrderKey memory orderKey) internal view returns (PoolKey memory poolKey) {
        return orderKey.sellToken < orderKey.buyToken
            ? PoolKey({
                token0: orderKey.sellToken,
                token1: orderKey.buyToken,
                config: toConfig({_fee: orderKey.fee, _tickSpacing: FULL_RANGE_ONLY_TICK_SPACING, _extension: address(this)})
            })
            : PoolKey({
                token0: orderKey.buyToken,
                token1: orderKey.sellToken,
                config: toConfig({_fee: orderKey.fee, _tickSpacing: FULL_RANGE_ONLY_TICK_SPACING, _extension: address(this)})
            });
    }

    function _executeVirtualOrdersFromWithinLock(PoolKey memory poolKey) internal {
        unchecked {
            bytes32 poolId = poolKey.toPoolId();

            uint32 lastVirtualOrderExecutionTime;
            uint112 saleRateToken0;
            uint112 saleRateToken1;
            {
                PoolState storage state = poolState[poolId];
                (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) =
                    (state.lastVirtualOrderExecutionTime, state.saleRateToken0, state.saleRateToken1);
            }

            // check the pool is initialized iff this is zero, otherwise we know it's initialized
            if (lastVirtualOrderExecutionTime == 0) {
                if (!poolInitialized[poolId]) revert PoolNotInitialized();
            }

            uint32 currentTime = uint32(block.timestamp);

            // no-op if already executed in this block
            if (lastVirtualOrderExecutionTime != currentTime) {
                FeesPerLiquidity memory rewardRates = poolRewardRates[poolId];

                int128 totalSwapDelta0;
                int128 totalSwapDelta1;

                while (lastVirtualOrderExecutionTime != currentTime) {
                    (uint32 nextTime, bool initialized) = poolInitializedTimesBitmap[poolId]
                        .searchForNextInitializedTime(lastVirtualOrderExecutionTime, currentTime);

                    uint32 timeElapsed = nextTime - lastVirtualOrderExecutionTime;

                    uint112 amount0 =
                        computeAmountFromSaleRate({saleRate: saleRateToken0, duration: timeElapsed, roundUp: false});

                    uint112 amount1 =
                        computeAmountFromSaleRate({saleRate: saleRateToken1, duration: timeElapsed, roundUp: false});

                    int128 delta0;
                    int128 delta1;

                    // if both sale rates are non-zero but amounts are zero, we will end up doing the math for no reason since we swap 0
                    if (amount0 != 0 && amount1 != 0) {
                        (SqrtRatio sqrtRatio,, uint128 liquidity) = core.poolState(poolId);
                        SqrtRatio sqrtRatioNext = computeNextSqrtRatio({
                            sqrtRatio: sqrtRatio,
                            liquidity: liquidity,
                            saleRateToken0: saleRateToken0,
                            saleRateToken1: saleRateToken1,
                            timeElapsed: timeElapsed,
                            fee: poolKey.fee()
                        });

                        if (sqrtRatioNext > sqrtRatio) {
                            (delta0, delta1) =
                                core.swap_611415377(poolKey, int128(uint128(amount1)), true, sqrtRatioNext, 0);
                        } else {
                            (delta0, delta1) =
                                core.swap_611415377(poolKey, int128(uint128(amount0)), false, sqrtRatioNext, 0);
                        }

                        totalSwapDelta0 += delta0;
                        totalSwapDelta1 += delta1;

                        delta0 -= int128(uint128(amount0));
                        delta1 -= int128(uint128(amount1));
                    } else if (amount0 != 0 || amount1 != 0) {
                        if (amount0 != 0) {
                            (delta0, delta1) =
                                core.swap_611415377(poolKey, int128(uint128(amount0)), false, MIN_SQRT_RATIO, 0);
                        } else {
                            (delta0, delta1) =
                                core.swap_611415377(poolKey, int128(uint128(amount1)), true, MAX_SQRT_RATIO, 0);
                        }

                        totalSwapDelta0 += delta0;
                        totalSwapDelta1 += delta1;
                    }

                    // some amount of token0 came out the pool
                    if (delta0 < 0) {
                        rewardRates.value0 += (uint256(-int256(delta0)) << 128) / saleRateToken1;
                    }

                    // some amount of token1 came out the pool
                    if (delta1 < 0) {
                        rewardRates.value1 += (uint256(-int256(delta1)) << 128) / saleRateToken0;
                    }

                    if (initialized) {
                        uint256 realTimeCrossed = block.timestamp + nextTime - currentTime;
                        poolRewardRatesBefore[poolId][realTimeCrossed] = rewardRates;

                        TimeInfo memory timeInfo = poolTimeInfos[poolId][realTimeCrossed];

                        saleRateToken0 = addSaleRateDelta(saleRateToken0, timeInfo.saleRateDeltaToken0);
                        saleRateToken1 = addSaleRateDelta(saleRateToken1, timeInfo.saleRateDeltaToken1);

                        // this time is _consumed_, will never be crossed again, so we delete the info we no longer need.
                        // this helps reduce the cost of executing virtual orders.
                        delete poolTimeInfos[poolId][realTimeCrossed];
                        poolInitializedTimesBitmap[poolId].flipTime(nextTime);
                    }

                    lastVirtualOrderExecutionTime = nextTime;
                }

                poolRewardRates[poolId] = rewardRates;

                assembly ("memory-safe") {
                    mstore(0, poolId)
                    mstore(32, 0)

                    sstore(
                        keccak256(0, 64),
                        add(add(lastVirtualOrderExecutionTime, shl(32, saleRateToken0)), shl(144, saleRateToken1))
                    )
                }

                core.save(
                    address(this),
                    poolKey.token0,
                    poolKey.token1,
                    bytes32(0),
                    uint128(uint256(-FixedPointMathLib.min(totalSwapDelta0, 0))),
                    uint128(uint256(-FixedPointMathLib.min(totalSwapDelta1, 0)))
                );

                core.load(
                    poolKey.token0,
                    poolKey.token1,
                    bytes32(0),
                    uint128(uint256(FixedPointMathLib.max(totalSwapDelta0, 0))),
                    uint128(uint256(FixedPointMathLib.max(totalSwapDelta1, 0)))
                );

                _emitVirtualOrdersExecuted(poolId, saleRateToken0, saleRateToken1);
            }
        }
    }

    // Must be called for a pool key that is already initialized
    function _lockAndExecuteVirtualOrders(PoolKey memory poolKey) internal {
        // the only thing we lock for is executing virtual orders, so all we need to encode is the pool key
        // so we call lock on the core contract with the pool key after it
        address target = address(core);
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, shl(224, 0xf83d08ba))
            mcopy(add(o, 4), poolKey, 96)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, o, 100, 0, 0)) {
                returndatacopy(o, 0, returndatasize())
                revert(o, returndatasize())
            }
        }
    }

    ///////////////////////// Extension call points /////////////////////////

    function afterInitializePool(address, PoolKey memory key, int32, SqrtRatio) external override onlyCore {
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();

        bytes32 poolId = key.toPoolId();
        poolState[poolId] = PoolState(uint32(block.timestamp), 0, 0);
        // we need this extra mapping since pool state can be zero for an initialized pool
        poolInitialized[poolId] = true;
        _emitVirtualOrdersExecuted(poolId, 0, 0);
    }

    function beforeSwap(address, PoolKey memory poolKey, int128, bool, SqrtRatio, uint256) external override onlyCore {
        _lockAndExecuteVirtualOrders(poolKey);
    }

    function beforeUpdatePosition(address, PoolKey memory poolKey, UpdatePositionParameters memory)
        external
        override
        onlyCore
    {
        _lockAndExecuteVirtualOrders(poolKey);
    }
}
