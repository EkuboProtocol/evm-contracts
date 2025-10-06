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
import {TWAMMStorageLayout} from "../libraries/TWAMMStorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {PoolState} from "../types/poolState.sol";
import {TwammPoolState, createTwammPoolState} from "../types/twammPoolState.sol";
import {OrderKey} from "../types/orderKey.sol";
import {OrderState, createOrderState} from "../types/orderState.sol";
import {searchForNextInitializedTime, flipTime} from "../math/timeBitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {computeFee} from "../math/fee.sol";
import {
    computeNextSqrtRatio, computeAmountFromSaleRate, computeRewardAmount, addSaleRateDelta
} from "../math/twamm.sol";
import {isTimeValid, MAX_ABS_VALUE_SALE_RATE_DELTA} from "../math/time.sol";
import {PoolId} from "../types/poolId.sol";
import {OrderId} from "../types/orderId.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {LibBit} from "solady/utils/LibBit.sol";

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
    function getRewardRateInside(PoolId poolId, uint64 startTime, uint64 endTime, bool isToken1)
        public
        view
        returns (uint256 result)
    {
        if (block.timestamp >= endTime) {
            uint256 rewardRateStart = uint256(
                StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, startTime)).add(
                    LibBit.rawToUint(isToken1)
                ).load()
            );
            uint256 rewardRateEnd = uint256(
                StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, endTime)).add(
                    LibBit.rawToUint(isToken1)
                ).load()
            );

            unchecked {
                result = rewardRateEnd - rewardRateStart;
            }
        } else if (block.timestamp > startTime) {
            //  note that we check gt because if it's equal to start time, then the reward rate inside is necessarily 0

            uint256 rewardRateStart = uint256(
                StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, startTime)).add(
                    LibBit.rawToUint(isToken1)
                ).load()
            );
            uint256 rewardRateCurrent = uint256(
                StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).add(LibBit.rawToUint(isToken1)).load()
            );

            unchecked {
                result = rewardRateCurrent - rewardRateStart;
            }
        } else {
            // less than or equal to start time
            // returns 0
        }
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
    {
        TimeInfo timeInfo = TimeInfo.wrap(StorageSlot.wrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time)).load());
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
            bytes32 zeroNumOrders = bytes32(LibBit.rawToUint(numOrders == 0));

            StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time)).storeTwo(
                zeroNumOrders, zeroNumOrders
            );

            flipTime(StorageSlot.wrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId)), time);
        }

        if (isToken1) {
            saleRateDeltaToken1 = _addConstrainSaleRateDelta(saleRateDeltaToken1, saleRateDelta);
        } else {
            saleRateDeltaToken0 = _addConstrainSaleRateDelta(saleRateDeltaToken0, saleRateDelta);
        }

        StorageSlot.wrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time)).store(
            TimeInfo.unwrap(createTimeInfo(numOrdersNext, saleRateDeltaToken0, saleRateDeltaToken1))
        );
    }

    /// @notice Returns the call points configuration for this extension
    /// @dev Overrides the base implementation to return TWAMM-specific call points
    /// @return The call points configuration
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return twammCallPoints();
    }

    ///////////////////////// Callbacks /////////////////////////

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            uint256 callType = abi.decode(data, (uint256));
            address owner = original.addr();

            if (callType == 0) {
                (, bytes32 salt, OrderKey memory orderKey, int112 saleRateDelta) =
                    abi.decode(data, (uint256, bytes32, OrderKey, int112));

                (uint64 startTime, uint64 endTime) = (orderKey.startTime(), orderKey.endTime());

                if (endTime <= block.timestamp) revert OrderAlreadyEnded();

                if (
                    !isTimeValid(block.timestamp, startTime) || !isTimeValid(block.timestamp, endTime)
                        || startTime >= endTime
                ) {
                    revert InvalidTimestamps();
                }

                PoolKey memory poolKey = orderKey.toPoolKey(address(this));
                PoolId poolId = poolKey.toPoolId();
                _executeVirtualOrdersFromWithinLock(poolKey, poolId);

                OrderId orderId = orderKey.toOrderId();

                StorageSlot orderStateSlot = StorageSlot.wrap(
                    TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
                );
                StorageSlot orderRewardRateSnapshotSlot = orderStateSlot.next();

                OrderState order = OrderState.wrap(orderStateSlot.load());
                uint256 rewardRateSnapshot = uint256(orderRewardRateSnapshotSlot.load());

                uint256 rewardRateInside = getRewardRateInside(poolId, startTime, endTime, !orderKey.isToken1());

                (uint32 lastUpdateTime, uint112 saleRate, uint112 amountSold) = order.parse();

                uint256 purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, saleRate);

                uint256 saleRateNext = addSaleRateDelta(saleRate, saleRateDelta);

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

                orderStateSlot.store(
                    OrderState.unwrap(
                        createOrderState({
                            _lastUpdateTime: uint32(block.timestamp),
                            _saleRate: uint112(saleRateNext),
                            _amountSold: uint112(
                                amountSold
                                    + computeAmountFromSaleRate({
                                        saleRate: saleRate,
                                        duration: FixedPointMathLib.min(
                                            uint32(block.timestamp) - lastUpdateTime, uint32(block.timestamp) - uint32(startTime)
                                        ),
                                        roundUp: false
                                    })
                            )
                        })
                    )
                );
                orderRewardRateSnapshotSlot.store(bytes32(rewardRateSnapshotAdjusted));

                bool isToken1 = orderKey.isToken1();

                if (block.timestamp < startTime) {
                    _updateTime(poolId, startTime, saleRateDelta, isToken1, numOrdersChange);
                    _updateTime(poolId, endTime, -int256(saleRateDelta), isToken1, numOrdersChange);
                } else {
                    // we know block.timestamp < orderKey.endTime because we validate that first
                    // and we know the order is active, so we have to apply its delta to the current pool state
                    StorageSlot currentStateSlot = StorageSlot.wrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));
                    TwammPoolState currentState = TwammPoolState.wrap(currentStateSlot.load());
                    (uint32 lastTime, uint112 rate0, uint112 rate1) = currentState.parse();

                    if (isToken1) {
                        currentState = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: lastTime,
                            _saleRateToken0: rate0,
                            _saleRateToken1: uint112(addSaleRateDelta(rate1, saleRateDelta))
                        });
                    } else {
                        currentState = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: lastTime,
                            _saleRateToken0: uint112(addSaleRateDelta(rate0, saleRateDelta)),
                            _saleRateToken1: rate1
                        });
                    }

                    currentStateSlot.store(TwammPoolState.unwrap(currentState));

                    // only update the end time
                    _updateTime(poolId, endTime, -int256(saleRateDelta), isToken1, numOrdersChange);
                }

                // we know this will fit in a uint32 because otherwise isValidTime would fail for the end time
                uint256 durationRemaining = endTime - FixedPointMathLib.max(block.timestamp, startTime);

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

                emit OrderUpdated(owner, salt, orderKey, saleRateDelta);

                result = abi.encode(amountDelta);
            } else if (callType == 1) {
                (, bytes32 salt, OrderKey memory orderKey) = abi.decode(data, (uint256, bytes32, OrderKey));

                PoolKey memory poolKey = orderKey.toPoolKey(address(this));
                PoolId poolId = poolKey.toPoolId();
                _executeVirtualOrdersFromWithinLock(poolKey, poolId);

                OrderId orderId = orderKey.toOrderId();

                StorageSlot orderStateSlot = StorageSlot.wrap(
                    TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
                );
                StorageSlot orderRewardRateSnapshotSlot = orderStateSlot.next();

                OrderState order = OrderState.wrap(orderStateSlot.load());
                uint256 rewardRateSnapshot = uint256(orderRewardRateSnapshotSlot.load());

                uint256 rewardRateInside =
                    getRewardRateInside(poolId, orderKey.startTime(), orderKey.endTime(), !orderKey.isToken1());

                uint256 purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, order.saleRate());

                orderRewardRateSnapshotSlot.store(bytes32(rewardRateInside));

                if (purchasedAmount != 0) {
                    if (orderKey.isToken1()) {
                        CORE.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), -int256(purchasedAmount), 0
                        );
                    } else {
                        CORE.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), 0, -int256(purchasedAmount)
                        );
                    }
                }

                emit OrderProceedsWithdrawn(original.addr(), salt, orderKey, uint128(purchasedAmount));

                result = abi.encode(purchasedAmount);
            } else {
                revert();
            }
        }
    }

    function _executeVirtualOrdersFromWithinLock(PoolKey memory poolKey, PoolId poolId) internal {
        unchecked {
            StorageSlot stateSlot = StorageSlot.wrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));
            TwammPoolState state = TwammPoolState.wrap(stateSlot.load());

            // we only conditionally load this if the state is coincidentally zero,
            // in order to not lock the pool if state is 0 but the pool _is_ initialized
            // this can only happen iff a pool has zero sale rates **and** an execution of virtual orders
            // happens on the uint32 boundary
            if (TwammPoolState.unwrap(state) == bytes32(0)) {
                if (poolKey.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
            }

            uint256 realLastVirtualOrderExecutionTime = state.realLastVirtualOrderExecutionTime();

            // no-op if already executed in this block
            if (realLastVirtualOrderExecutionTime != block.timestamp) {
                // initialize the values that are handled once per execution
                FeesPerLiquidity memory rewardRates;
                bool rewardRate0Updated;
                bool rewardRate1Updated;
                int256 saveDelta0;
                int256 saveDelta1;
                PoolState corePoolState;
                uint256 time = realLastVirtualOrderExecutionTime;

                while (time != block.timestamp) {
                    StorageSlot initializedTimesBitmapSlot =
                        StorageSlot.wrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId));

                    (uint256 nextTime, bool initialized) = searchForNextInitializedTime({
                        slot: initializedTimesBitmapSlot,
                        lastVirtualOrderExecutionTime: realLastVirtualOrderExecutionTime,
                        fromTime: time,
                        untilTime: block.timestamp
                    });

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
                                CORE.swap(0, poolKey, int128(uint128(amount1)), true, sqrtRatioNext, 0);
                        } else if (sqrtRatioNext < corePoolState.sqrtRatio()) {
                            (swapDelta0, swapDelta1, corePoolState) =
                                CORE.swap(0, poolKey, int128(uint128(amount0)), false, sqrtRatioNext, 0);
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
                                CORE.swap(0, poolKey, int128(uint128(amount0)), false, MIN_SQRT_RATIO, 0);
                        } else {
                            (rewardDelta0, rewardDelta1, corePoolState) =
                                CORE.swap(0, poolKey, int128(uint128(amount1)), true, MAX_SQRT_RATIO, 0);
                        }

                        saveDelta0 -= rewardDelta0;
                        saveDelta1 -= rewardDelta1;
                    }

                    if (rewardDelta0 < 0) {
                        if (!rewardRate0Updated) {
                            rewardRates.value0 =
                                uint256(StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).load());
                            rewardRate0Updated = true;
                        }
                        rewardRates.value0 +=
                            FixedPointMathLib.rawDiv(uint256(-rewardDelta0) << 128, state.saleRateToken1());
                    }

                    if (rewardDelta1 < 0) {
                        if (!rewardRate1Updated) {
                            rewardRates.value1 =
                                uint256(StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).next().load());
                            rewardRate1Updated = true;
                        }
                        rewardRates.value1 +=
                            FixedPointMathLib.rawDiv(uint256(-rewardDelta1) << 128, state.saleRateToken0());
                    }

                    if (initialized) {
                        if (!rewardRate0Updated) {
                            rewardRates.value0 =
                                uint256(StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).load());
                        }
                        if (!rewardRate1Updated) {
                            rewardRates.value1 =
                                uint256(StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).next().load());
                        }

                        StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, nextTime)).storeTwo(
                            bytes32(rewardRates.value0), bytes32(rewardRates.value1)
                        );

                        StorageSlot timeInfoSlot =
                            StorageSlot.wrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, nextTime));
                        (, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1) =
                            TimeInfo.wrap(timeInfoSlot.load()).parse();

                        state = createTwammPoolState({
                            _lastVirtualOrderExecutionTime: uint32(nextTime),
                            _saleRateToken0: uint112(addSaleRateDelta(state.saleRateToken0(), saleRateDeltaToken0)),
                            _saleRateToken1: uint112(addSaleRateDelta(state.saleRateToken1(), saleRateDeltaToken1))
                        });

                        // this time is _consumed_, will never be crossed again, so we delete the info we no longer need.
                        // this helps reduce the cost of executing virtual orders.
                        timeInfoSlot.store(0);

                        flipTime(initializedTimesBitmapSlot, nextTime);
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

                if (rewardRate0Updated) {
                    StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).store(bytes32(rewardRates.value0));
                }
                if (rewardRate1Updated) {
                    StorageSlot.wrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId)).next().store(
                        bytes32(rewardRates.value1)
                    );
                }

                stateSlot.store(TwammPoolState.unwrap(state));

                _emitVirtualOrdersExecuted(poolId, state.saleRateToken0(), state.saleRateToken1());
            }
        }
    }

    // Executes virtual orders for the specified initialized pool key. Protected because it is only called by core.
    function locked_6416899205(uint256) external override onlyCore {
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

        StorageSlot.wrap(TWAMMStorageLayout.twammPoolStateSlot(poolId)).store(
            TwammPoolState.unwrap(
                createTwammPoolState({
                    _lastVirtualOrderExecutionTime: uint32(block.timestamp),
                    _saleRateToken0: 0,
                    _saleRateToken1: 0
                })
            )
        );

        _emitVirtualOrdersExecuted({poolId: poolId, saleRateToken0: 0, saleRateToken1: 0});
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeSwap(Locker, PoolKey memory poolKey, SwapParameters) external override(BaseExtension, IExtension) {
        lockAndExecuteVirtualOrders(poolKey);
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeUpdatePosition(Locker, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
    {
        lockAndExecuteVirtualOrders(poolKey);
    }

    // Since anyone can call the method `#lockAndExecuteVirtualOrders`, the method is not protected
    function beforeCollectFees(Locker, PoolKey memory poolKey, PositionId)
        external
        override(BaseExtension, IExtension)
    {
        lockAndExecuteVirtualOrders(poolKey);
    }
}
