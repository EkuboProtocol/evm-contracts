// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../types/sqrtRatio.sol";
import {ICore, IExtension} from "../interfaces/ICore.sol";
import {ITWAMM} from "../interfaces/extensions/ITWAMM.sol";
import {TimeInfo, createTimeInfo} from "../types/timeInfo.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {Bitmap} from "../types/bitmap.sol";
import {PoolState} from "../types/poolState.sol";
import {TwammPoolState, createTwammPoolState} from "../types/twammPoolState.sol";
import {OrderState, createOrderState} from "../types/orderState.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {computeFee} from "../math/fee.sol";
import {
    computeNextSqrtRatio, computeAmountFromSaleRate, computeRewardAmount, addSaleRateDelta
} from "../math/twamm.sol";
import {isTimeValid, nextValidTime, MAX_ABS_VALUE_SALE_RATE_DELTA} from "../math/time.sol";
import {PoolId} from "../types/poolId.sol";
import {TWAMMStorageLayout} from "../libraries/TWAMMStorageLayout.sol";

/// @notice Returns the call points configuration for the TWAMM extension
/// @dev Specifies which hooks TWAMM needs to execute virtual orders and manage DCA functionality
/// @return The call points configuration for TWAMM functionality
function twammCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: true,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: false,
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @title Ekubo TWAMM (Time-Weighted Average Market Maker)
/// @author Moody Salem <moody@ekubo.org>
/// @notice Extension for Ekubo Protocol that enables creation of DCA (Dollar Cost Averaging) orders that are executed over time
/// @dev Implements virtual order execution that spreads trades over time periods to reduce price impact and provide better execution
contract TWAMM is ITWAMM, ExposedStorage, BaseExtension, BaseForwardee {
    using CoreLib for *;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    /// @notice Emits an event for virtual order execution
    /// @dev Emits an event for the virtual order execution. Assumes that saleRateToken0 and saleRateToken1 are <= type(uint112).max
    /// @param poolId The unique identifier for the pool
    /// @param saleRateToken0 The sale rate for token0 orders
    /// @param saleRateToken1 The sale rate for token1 orders
    function _emitVirtualOrdersExecuted(PoolId poolId, uint256 saleRateToken0, uint256 saleRateToken1) internal {
        assembly ("memory-safe") {
            // by writing it backwards, we overwrite only the empty bits with each subsequent write
            // 28-60, only 46-60 can be non-zero
            mstore(28, saleRateToken1)
            // 14-46, only 32-46 can be non-zero
            mstore(14, saleRateToken0)
            mstore(0, poolId)

            log0(0, 60)
        }
    }

    /// @inheritdoc ITWAMM
    function getRewardRateInside(PoolId poolId, uint256 startTime, uint256 endTime, bool isToken1)
        public
        view
        virtual
        returns (uint256 result)
    {
        if (block.timestamp >= endTime) {
            bytes32 baseSlotStart = TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, startTime);
            bytes32 baseSlotEnd = TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, endTime);
            assembly ("memory-safe") {
                let rewardRateStart := sload(add(baseSlotStart, isToken1))
                let rewardRateEnd := sload(add(baseSlotEnd, isToken1))
                result := sub(rewardRateEnd, rewardRateStart)
            }
        } else if (block.timestamp > startTime) {
            bytes32 rewardRatesSlot = TWAMMStorageLayout.poolRewardRatesSlot(poolId);
            bytes32 baseSlotStart = TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, startTime);
            assembly ("memory-safe") {
                let rewardRateCurrent := sload(add(rewardRatesSlot, isToken1))
                let rewardRateStart := sload(add(baseSlotStart, isToken1))
                result := sub(rewardRateCurrent, rewardRateStart)
            }
        }
        // else: less than or equal to start time, returns 0 (default)
    }

    /// @notice Safely adds a change to a sale rate delta with overflow protection
    /// @dev Ensures the resulting sale rate delta doesn't exceed the maximum allowed value
    /// @param saleRateDelta The current sale rate delta
    /// @param saleRateDeltaChange The change to apply to the sale rate delta
    /// @return saleRateDeltaNext The new sale rate delta after applying the change
    function _addConstrainSaleRateDelta(int112 saleRateDelta, int256 saleRateDeltaChange)
        internal
        pure
        returns (int112 saleRateDeltaNext)
    {
        int256 result = int256(saleRateDelta) + saleRateDeltaChange;

        // checked addition, no overflow of int112 type
        if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            revert MaxSaleRateDeltaPerTime();
        }

        // we know cast is safe because abs(result) is less than MAX_ABS_VALUE_SALE_RATE_DELTA which fits in a int112
        saleRateDeltaNext = int112(result);
    }

    /// @notice Updates time-specific information for TWAMM orders
    /// @dev Manages the sale rate deltas and order counts for a specific time point
    /// @param poolId The unique identifier for the pool
    /// @param time The timestamp to update
    /// @param saleRateDelta The change in sale rate for this time
    /// @param isToken1 True if updating token1 sale rate, false for token0
    /// @param numOrdersChange The change in number of orders referencing this time
    function _updateTime(PoolId poolId, uint256 time, int256 saleRateDelta, bool isToken1, int256 numOrdersChange)
        internal
        virtual
    {
        TimeInfo timeInfo;
        assembly ("memory-safe") {
            timeInfo := sload(add(add(poolId, shl(224, 0x03)), time))
        }
        (uint32 numOrders, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1) = timeInfo.parse();

        // note we assume this will never overflow, since it would require 2**32 separate orders to be placed
        uint32 numOrdersNext;
        assembly ("memory-safe") {
            numOrdersNext := add(numOrders, numOrdersChange)
            if gt(numOrdersNext, 0xffffffff) {
                // cast sig "TimeNumOrdersOverflow()"
                mstore(0, shl(224, 0x6916a952))
                revert(0, 4)
            }
        }

        bool flip = (numOrders == 0) != (numOrdersNext == 0);

        // write the poolRewardRatesBefore[poolId][time] = (1,1) if any orders still reference the time, or write (0,0) otherwise
        // we assume `_updateTime` is being called only for times that are greater than block.timestamp, i.e. have not been crossed yet
        // this reduces the cost of crossing that timestamp to a warm write instead of a cold write
        if (flip) {
            assembly ("memory-safe") {
                // FeesPerLiquidity takes 2 slots, so we multiply time by 2
                let slot0 := add(add(poolId, shl(224, 0x04)), mul(time, 2))
                sstore(slot0, iszero(numOrders))
                sstore(add(slot0, 1), iszero(numOrders))
            }
            _flipTime(poolId, time);
        }

        if (isToken1) {
            saleRateDeltaToken1 = _addConstrainSaleRateDelta(saleRateDeltaToken1, saleRateDelta);
        } else {
            saleRateDeltaToken0 = _addConstrainSaleRateDelta(saleRateDeltaToken0, saleRateDelta);
        }

        TimeInfo newTimeInfo = createTimeInfo(numOrdersNext, saleRateDeltaToken0, saleRateDeltaToken1);
        assembly ("memory-safe") {
            sstore(add(add(poolId, shl(224, 0x03)), time), newTimeInfo)
        }
    }

    /// @notice Flips a time bit in the initialized times bitmap
    /// @param poolId The unique identifier for the pool
    /// @param time The time to flip
    function _flipTime(PoolId poolId, uint256 time) internal {
        assembly ("memory-safe") {
            // With 16-second granularity: word = time >> 12, bit = (time >> 4) & 0xff
            let word := shr(12, time)
            let bit := and(shr(4, time), 0xff)
            let slot := add(add(poolId, shl(224, 0x02)), word)
            let bitmap := sload(slot)
            sstore(slot, xor(bitmap, shl(bit, 1)))
        }
    }

    /// @dev Efficiently finds the next initialized time using word-level bitmap scanning
    /// @param poolId The pool identifier
    /// @param lastVirtualOrderExecutionTime The last time virtual orders were executed (basis for nextValidTime)
    /// @param fromTime The current time to search from
    /// @param untilTime The maximum time to search until
    /// @return nextTime The next initialized time, or untilTime if none found
    function _findNextInitializedTime(
        PoolId poolId,
        uint256 lastVirtualOrderExecutionTime,
        uint256 fromTime,
        uint256 untilTime
    ) internal view returns (uint256 nextTime) {
        // Get the first valid time after the current time
        nextTime = nextValidTime(lastVirtualOrderExecutionTime, fromTime + 1);
        if (nextTime == 0 || nextTime > untilTime) {
            return untilTime;
        }

        // Start from the next valid time and scan for initialized times
        uint256 candidate = nextTime;

        while (candidate <= untilTime) {
            // Convert candidate to word and bit index (16-second granularity, 256 bits per word)
            uint256 word = candidate >> 12; // candidate / 4096 (256 * 16)
            uint256 bitIndex = (candidate >> 4) & 0xff; // (candidate / 16) % 256

            // Load the bitmap word
            uint256 bitmapWord;
            assembly ("memory-safe") {
                let slot := add(add(poolId, shl(224, 0x02)), word)
                bitmapWord := sload(slot)
            }

            // Check if this candidate time is initialized
            if ((bitmapWord >> bitIndex) & 1 != 0) {
                return candidate;
            }

            // Move to the next valid time
            uint256 nextCandidate = nextValidTime(lastVirtualOrderExecutionTime, candidate + 1);
            if (nextCandidate == 0 || nextCandidate <= candidate) {
                // No more valid times or we've wrapped around
                break;
            }
            candidate = nextCandidate;
        }

        return untilTime;
    }

    /// @notice Returns the call points configuration for this extension
    /// @dev Overrides the base implementation to return TWAMM-specific call points
    /// @return The call points configuration
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

                PoolKey memory poolKey = params.orderKey.toPoolKey(address(this));
                PoolId poolId = poolKey.toPoolId();
                _executeVirtualOrdersFromWithinLock(poolKey, poolId);

                bytes32 orderId = params.orderKey.toOrderId();
                bytes32 orderStateSlot = TWAMMStorageLayout.orderStateSlot(originalLocker, params.salt, orderId);
                bytes32 rewardRateSnapshotSlot =
                    TWAMMStorageLayout.orderRewardRateSnapshotSlot(originalLocker, params.salt, orderId);
                OrderState order;
                uint256 rewardRateSnapshot;
                assembly ("memory-safe") {
                    order := sload(orderStateSlot)
                    rewardRateSnapshot := sload(rewardRateSnapshotSlot)
                }

                uint256 rewardRateInside = getRewardRateInside(
                    poolId,
                    params.orderKey.startTime,
                    params.orderKey.endTime,
                    params.orderKey.sellToken < params.orderKey.buyToken
                );

                (uint32 lastUpdateTime, uint112 saleRate, uint112 amountSold) = order.parse();

                uint256 purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, saleRate);

                uint256 saleRateNext = addSaleRateDelta(saleRate, params.saleRateDelta);

                if (saleRateNext == 0 && purchasedAmount != 0) {
                    revert MustCollectProceedsBeforeCanceling();
                }

                uint256 rewardRateSnapshotAdjusted;
                int256 numOrdersChange;
                assembly ("memory-safe") {
                    rewardRateSnapshotAdjusted :=
                        mul(
                            sub(rewardRateInside, div(shl(128, purchasedAmount), saleRateNext)),
                            // if saleRateNext is zero, write 0 for the reward rate snapshot adjusted
                            iszero(iszero(saleRateNext))
                        )

                    // if current is zero, and next is zero, then 1-1 = 0
                    // if current is nonzero, and next is nonzero, then 0-0 = 0
                    // if current is zero, and next is nonzero, then we get 1-0 = 1
                    // if current is nonzero, and next is zero, then we get 0-1 = -1 = (type(uint256).max)
                    numOrdersChange := sub(iszero(saleRate), iszero(saleRateNext))
                }

                OrderState newOrderState = createOrderState({
                    _lastUpdateTime: uint32(block.timestamp),
                    _saleRate: uint112(saleRateNext),
                    _amountSold: uint112(
                        amountSold
                            + computeAmountFromSaleRate({
                                saleRate: saleRate,
                                duration: FixedPointMathLib.min(
                                    uint32(block.timestamp) - lastUpdateTime,
                                    uint32(block.timestamp) - uint32(params.orderKey.startTime)
                                ),
                                roundUp: false
                            })
                    )
                });
                assembly ("memory-safe") {
                    sstore(orderStateSlot, newOrderState)
                    sstore(rewardRateSnapshotSlot, rewardRateSnapshotAdjusted)
                }

                bool isToken1 = params.orderKey.sellToken > params.orderKey.buyToken;

                if (block.timestamp < params.orderKey.startTime) {
                    _updateTime(poolId, params.orderKey.startTime, params.saleRateDelta, isToken1, numOrdersChange);
                    _updateTime(
                        poolId, params.orderKey.endTime, -int256(params.saleRateDelta), isToken1, numOrdersChange
                    );
                } else {
                    // we know block.timestamp < params.orderKey.endTime because we validate that first
                    // and we know the order is active, so we have to apply its delta to the current pool state
                    TwammPoolState currentState;
                    assembly ("memory-safe") {
                        currentState := sload(poolId)
                    }
                    (uint32 lastTime, uint112 rate0, uint112 rate1) = currentState.parse();

                    if (isToken1) {
                        currentState = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: lastTime,
                            _saleRateToken0: rate0,
                            _saleRateToken1: uint112(addSaleRateDelta(rate1, params.saleRateDelta))
                        });
                    } else {
                        currentState = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: lastTime,
                            _saleRateToken0: uint112(addSaleRateDelta(rate0, params.saleRateDelta)),
                            _saleRateToken1: rate1
                        });
                    }

                    assembly ("memory-safe") {
                        sstore(poolId, currentState)
                    }

                    // only update the end time
                    _updateTime(
                        poolId, params.orderKey.endTime, -int256(params.saleRateDelta), isToken1, numOrdersChange
                    );
                }

                // we know this will fit in a uint32 because otherwise isValidTime would fail for the end time
                uint256 durationRemaining =
                    params.orderKey.endTime - FixedPointMathLib.max(block.timestamp, params.orderKey.startTime);

                // the amount required for executing at the next sale rate for the remaining duration of the order
                uint256 amountRequired =
                    computeAmountFromSaleRate({saleRate: saleRateNext, duration: durationRemaining, roundUp: true});

                // subtract the remaining sell amount to get the delta
                int256 amountDelta;

                uint256 remainingSellAmount =
                    computeAmountFromSaleRate({saleRate: saleRate, duration: durationRemaining, roundUp: true});

                assembly ("memory-safe") {
                    amountDelta := sub(amountRequired, remainingSellAmount)
                }

                // user is withdrawing tokens, so they need to pay a fee to the liquidity providers
                if (amountDelta < 0) {
                    // negation and downcast will never overflow, since max sale rate times max duration is at most type(uint112).max
                    uint128 fee = computeFee(uint128(uint256(-amountDelta)), poolKey.fee());
                    if (isToken1) {
                        CORE.accumulateAsFees(poolKey, 0, fee);
                        CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), 0, amountDelta);
                    } else {
                        CORE.accumulateAsFees(poolKey, fee, 0);
                        CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), amountDelta, 0);
                    }

                    amountDelta += int128(fee);
                } else {
                    if (isToken1) {
                        CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), 0, amountDelta);
                    } else {
                        CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), amountDelta, 0);
                    }
                }

                emit OrderUpdated(originalLocker, params.salt, params.orderKey, params.saleRateDelta);

                result = abi.encode(amountDelta);
            } else if (callType == 1) {
                (, ITWAMM.CollectProceedsParams memory params) =
                    abi.decode(data, (uint256, ITWAMM.CollectProceedsParams));

                PoolKey memory poolKey = params.orderKey.toPoolKey(address(this));
                PoolId poolId = poolKey.toPoolId();
                _executeVirtualOrdersFromWithinLock(poolKey, poolId);

                bytes32 orderId = params.orderKey.toOrderId();
                bytes32 orderStateSlot = TWAMMStorageLayout.orderStateSlot(originalLocker, params.salt, orderId);
                bytes32 rewardRateSnapshotSlot =
                    TWAMMStorageLayout.orderRewardRateSnapshotSlot(originalLocker, params.salt, orderId);
                OrderState order;
                uint256 rewardRateSnapshot;
                assembly ("memory-safe") {
                    order := sload(orderStateSlot)
                    rewardRateSnapshot := sload(rewardRateSnapshotSlot)
                }
                uint256 rewardRateInside = getRewardRateInside(
                    poolId,
                    params.orderKey.startTime,
                    params.orderKey.endTime,
                    params.orderKey.sellToken < params.orderKey.buyToken
                );

                uint256 purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, order.saleRate());
                assembly ("memory-safe") {
                    sstore(rewardRateSnapshotSlot, rewardRateInside)
                }

                if (purchasedAmount != 0) {
                    if (params.orderKey.sellToken > params.orderKey.buyToken) {
                        CORE.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), -int256(purchasedAmount), 0
                        );
                    } else {
                        CORE.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), 0, -int256(purchasedAmount)
                        );
                    }
                }

                emit OrderProceedsWithdrawn(originalLocker, params.salt, params.orderKey, uint128(purchasedAmount));

                result = abi.encode(purchasedAmount);
            } else {
                revert();
            }
        }
    }

    function _executeVirtualOrdersFromWithinLock(PoolKey memory poolKey, PoolId poolId) internal {
        unchecked {
            TwammPoolState state;

            // load the pool state
            assembly ("memory-safe") {
                state := sload(poolId)

                if iszero(state) {
                    // we only conditionally load this if state is coincidentally zero,
                    // in order to not lock the pool if state is 0 but the pool _is_ initialized
                    // this can only happen iff a pool has zero sale rates **and** an execution of virtual orders
                    // happens on the uint32 boundary
                    if iszero(sload(add(poolId, 1))) {
                        // cast sig "PoolNotInitialized()"
                        mstore(0, shl(224, 0x486aa307))
                        revert(0, 4)
                    }
                }
            }

            uint256 realLastVirtualOrderExecutionTime = state.realLastVirtualOrderExecutionTime();

            // no-op if already executed in this block
            if (realLastVirtualOrderExecutionTime != block.timestamp) {
                // initialize the values that are handled once per execution
                FeesPerLiquidity memory rewardRates;
                assembly ("memory-safe") {
                    let slot := add(add(poolId, shl(224, 0x01)), 0)
                    mstore(rewardRates, sload(slot))
                    mstore(add(rewardRates, 32), sload(add(slot, 1)))
                }
                int256 saveDelta0;
                int256 saveDelta1;
                PoolState corePoolState;
                uint256 time = realLastVirtualOrderExecutionTime;

                while (time != block.timestamp) {
                    // Find next initialized time using word-level bitmap scanning
                    uint256 nextTime =
                        _findNextInitializedTime(poolId, realLastVirtualOrderExecutionTime, time, block.timestamp);

                    // it is assumed that this will never return a value greater than type(uint32).max
                    uint256 timeElapsed = nextTime - time;

                    uint256 amount0 = computeAmountFromSaleRate({
                        saleRate: state.saleRateToken0(),
                        duration: timeElapsed,
                        roundUp: false
                    });

                    uint256 amount1 = computeAmountFromSaleRate({
                        saleRate: state.saleRateToken1(),
                        duration: timeElapsed,
                        roundUp: false
                    });

                    int256 rewardDelta0;
                    int256 rewardDelta1;
                    // if both sale rates are non-zero but amounts are zero, we will end up doing the math for no reason since we swap 0
                    if (amount0 != 0 && amount1 != 0) {
                        if (!corePoolState.isInitialized()) {
                            corePoolState = CORE.poolState(poolId);
                        }
                        SqrtRatio sqrtRatioNext = computeNextSqrtRatio({
                            sqrtRatio: corePoolState.sqrtRatio(),
                            liquidity: corePoolState.liquidity(),
                            saleRateToken0: state.saleRateToken0(),
                            saleRateToken1: state.saleRateToken1(),
                            timeElapsed: timeElapsed,
                            fee: poolKey.fee()
                        });

                        int256 swapDelta0;
                        int256 swapDelta1;
                        if (sqrtRatioNext > corePoolState.sqrtRatio()) {
                            // todo: we could update corePoolState here and avoid calling into core to get it again
                            // however it causes stack too deep and it's not a huge optimization because in cases where two tokens are sold
                            (swapDelta0, swapDelta1, corePoolState) =
                                CORE.swap_611415377(poolKey, int128(uint128(amount1)), true, sqrtRatioNext, 0);
                        } else if (sqrtRatioNext < corePoolState.sqrtRatio()) {
                            (swapDelta0, swapDelta1, corePoolState) =
                                CORE.swap_611415377(poolKey, int128(uint128(amount0)), false, sqrtRatioNext, 0);
                        }

                        saveDelta0 -= swapDelta0;
                        saveDelta1 -= swapDelta1;

                        // this cannot overflow or underflow because swapDelta0 is constrained to int128,
                        // and amounts computed from uint112 sale rates cannot exceed uint112.max
                        rewardDelta0 = swapDelta0 - int256(uint256(amount0));
                        rewardDelta1 = swapDelta1 - int256(uint256(amount1));
                    } else if (amount0 != 0 || amount1 != 0) {
                        if (amount0 != 0) {
                            (rewardDelta0, rewardDelta1, corePoolState) =
                                CORE.swap_611415377(poolKey, int128(uint128(amount0)), false, MIN_SQRT_RATIO, 0);
                        } else {
                            (rewardDelta0, rewardDelta1, corePoolState) =
                                CORE.swap_611415377(poolKey, int128(uint128(amount1)), true, MAX_SQRT_RATIO, 0);
                        }

                        saveDelta0 -= rewardDelta0;
                        saveDelta1 -= rewardDelta1;
                    }

                    if (rewardDelta0 < 0) {
                        rewardRates.value0 += (uint256(-rewardDelta0) << 128) / state.saleRateToken1();
                    }

                    if (rewardDelta1 < 0) {
                        rewardRates.value1 += (uint256(-rewardDelta1) << 128) / state.saleRateToken0();
                    }

                    // Check if this time has orders (is initialized)
                    TimeInfo timeInfo;
                    assembly ("memory-safe") {
                        timeInfo := sload(add(add(poolId, shl(224, 0x03)), nextTime))
                    }
                    bool initialized = TimeInfo.unwrap(timeInfo) != 0;

                    if (initialized) {
                        assembly ("memory-safe") {
                            let slot := add(add(poolId, shl(224, 0x04)), mul(nextTime, 2))
                            sstore(slot, mload(rewardRates))
                            sstore(add(slot, 1), mload(add(rewardRates, 32)))
                        }

                        (, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1) = timeInfo.parse();

                        state = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: uint32(nextTime),
                            _saleRateToken0: uint112(addSaleRateDelta(state.saleRateToken0(), saleRateDeltaToken0)),
                            _saleRateToken1: uint112(addSaleRateDelta(state.saleRateToken1(), saleRateDeltaToken1))
                        });

                        // this time is _consumed_, will never be crossed again, so we delete the info we no longer need.
                        // this helps reduce the cost of executing virtual orders.
                        assembly ("memory-safe") {
                            sstore(add(add(poolId, shl(224, 0x03)), nextTime), 0)
                        }
                        _flipTime(poolId, nextTime);
                    } else {
                        state = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: uint32(nextTime),
                            _saleRateToken0: state.saleRateToken0(),
                            _saleRateToken1: state.saleRateToken1()
                        });
                    }

                    time = nextTime;
                }

                if (saveDelta0 != 0 || saveDelta1 != 0) {
                    CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), saveDelta0, saveDelta1);
                }

                assembly ("memory-safe") {
                    let slot := add(add(poolId, shl(224, 0x01)), 0)
                    sstore(slot, mload(rewardRates))
                    sstore(add(slot, 1), mload(add(rewardRates, 32)))
                    sstore(poolId, state)
                }

                _emitVirtualOrdersExecuted(poolId, state.saleRateToken0(), state.saleRateToken1());
            }
        }
    }

    // Executes virtual orders for the specified initialized pool key. Protected because it is only called by core.
    function locked(uint256) external override onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            poolKey := mload(0x40)
            // points the free memory pointer at pointer + 96
            mstore(0x40, add(poolKey, 96))

            // copy the poolkey out of calldata at the free memory pointer
            calldatacopy(poolKey, 36, 96)
        }
        _executeVirtualOrdersFromWithinLock(poolKey, poolKey.toPoolId());
    }

    /// @inheritdoc ITWAMM
    function lockAndExecuteVirtualOrders(PoolKey memory poolKey) public {
        // the only thing we lock for is executing virtual orders, so all we need to encode is the pool key
        // so we call lock on the core contract with the pool key after it
        address target = address(CORE);
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

    // This method must be protected because it sets state directly
    function afterInitializePool(address, PoolKey memory key, int32, SqrtRatio)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();

        PoolId poolId = key.toPoolId();

        TwammPoolState initialState = createTwammPoolState({
            _lastVirtualOrderExecutionTime: uint32(block.timestamp),
            _saleRateToken0: 0,
            _saleRateToken1: 0
        });
        assembly ("memory-safe") {
            sstore(poolId, initialState)
            // Auxiliary mapping that just indicates whether a pool is indeed initialized
            // This is only checked in the case that lastVirtualOrderExecutionTime and both sale rates in the pool state are zero
            sstore(add(poolId, 1), 1)
        }

        _emitVirtualOrdersExecuted({poolId: poolId, saleRateToken0: 0, saleRateToken1: 0});
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeSwap(address, PoolKey memory poolKey, int128, bool, SqrtRatio, uint256)
        external
        override(BaseExtension, IExtension)
    {
        lockAndExecuteVirtualOrders(poolKey);
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeUpdatePosition(address, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
    {
        lockAndExecuteVirtualOrders(poolKey);
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeCollectFees(address, PoolKey memory poolKey, PositionId)
        external
        override(BaseExtension, IExtension)
    {
        lockAndExecuteVirtualOrders(poolKey);
    }
}
