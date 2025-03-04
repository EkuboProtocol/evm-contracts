// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, toConfig} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PositionKey, Bounds} from "../types/positionKey.sol";
import {ILocker} from "../interfaces/IFlashAccountant.sol";
import {ICore, UpdatePositionParameters} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {Bitmap} from "../math/bitmap.sol";
import {searchForNextInitializedTime, flipTime} from "../math/timeBitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {computeFee} from "../math/fee.sol";
import {
    computeNextSqrtRatio, computeAmountFromSaleRate, computeRewardAmount, addSaleRateDelta
} from "../math/twamm.sol";
import {isTimeValid} from "../math/time.sol";

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
    using CoreLib for ICore;

    event OrderUpdated(address owner, bytes32 salt, OrderKey orderKey, int112 saleRateDelta);

    error TimeNumOrdersOverflow();
    error TickSpacingMustBeMaximum();
    error OrderAlreadyEnded();
    error InvalidTimestamps();
    error MustCollectProceedsBeforeCanceling();

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

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function _emitVirtualOrdersExecuted(bytes32 poolId, uint112 saleRateToken0, uint112 saleRateToken1) internal {
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(14, saleRateToken0)
            mstore(28, saleRateToken1)
            log0(0, 60)
        }
    }

    // Must be called for a pool key that is already initialized
    function _executeVirtualOrders(PoolKey memory poolKey) internal {
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

    // Must be called on a pool that is executed up to the current timestamp
    function _getOrderInfo(address owner, bytes32 salt, OrderKey memory orderKey)
        internal
        view
        returns (uint112 saleRate, uint256 rewardRateInside, uint128 remainingSellAmount, uint128 purchasedAmount)
    {
        OrderState memory order = orderState[owner][salt][orderKey.toOrderId()];

        unchecked {
            saleRate = order.saleRate;
            rewardRateInside = _getRewardRateInside(
                _orderKeyToPoolKey(orderKey).toPoolId(),
                orderKey.startTime,
                orderKey.endTime,
                orderKey.sellToken > orderKey.buyToken
            );
            remainingSellAmount = computeAmountFromSaleRate(
                order.saleRate,
                uint32(
                    FixedPointMathLib.max(orderKey.endTime, block.timestamp)
                        - FixedPointMathLib.max(orderKey.startTime, block.timestamp)
                ),
                false
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
            switch gt(timestamp(), endTime)
            case 1 {
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
            timeInfo.saleRateDeltaToken1 += saleRateDelta;
        } else {
            timeInfo.saleRateDeltaToken0 += saleRateDelta;
        }

        poolTimeInfos[poolId][time] = timeInfo;
    }

    function locked(uint256) external override onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            poolKey := mload(0x40)
            // copy the poolkey out of calldata at the free memory pointer
            calldatacopy(poolKey, 36, 96)
            // points the free memory pointer at pointer + 96
            mstore(poolKey, add(poolKey, 96))
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
                    !isTimeValid(params.orderKey.startTime, block.timestamp)
                        || !isTimeValid(params.orderKey.endTime, block.timestamp)
                        || params.orderKey.startTime >= params.orderKey.endTime
                ) {
                    revert InvalidTimestamps();
                }

                PoolKey memory poolKey = _orderKeyToPoolKey(params.orderKey);
                bytes32 poolId = poolKey.toPoolId();
                _executeVirtualOrdersFromWithinLock(poolKey);

                (uint112 saleRate, uint256 rewardRateSnapshot, uint128 remainingSellAmount, uint128 purchasedAmount) =
                    _getOrderInfo(originalLocker, params.salt, params.orderKey);

                uint112 saleRateNext = addSaleRateDelta(saleRate, params.saleRateDelta);

                if (saleRateNext == 0 && purchasedAmount != 0) {
                    revert MustCollectProceedsBeforeCanceling();
                }

                uint256 rewardRateSnapshotAdjusted;
                int256 numOrdersChange;
                assembly ("memory-safe") {
                    // if saleRateNext is 0, the adjusted amount is just rewardRateSnapshot because div returns 0 for 0 denominator
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
                    _updateTime(poolId, params.orderKey.endTime, -params.saleRateDelta, isToken1, numOrdersChange);
                }

                // the amount required for executing at the next sale rate for the remaining duration of the order
                uint256 amountRequired = computeAmountFromSaleRate({
                    saleRate: saleRateNext,
                    duration: uint32(
                        params.orderKey.endTime - FixedPointMathLib.max(block.timestamp, params.orderKey.startTime)
                    ),
                    roundUp: true
                });

                // subtract the remaining sell amount to get the delta
                int256 amountDelta;
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

                _executeVirtualOrdersFromWithinLock(_orderKeyToPoolKey(params.orderKey));
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
        bytes32 poolId = poolKey.toPoolId();

        PoolState memory state = poolState[poolId];
        uint32 currentTime = uint32(block.timestamp);

        // no-op if already executed in this block
        if (state.lastVirtualOrderExecutionTime != currentTime) {
            FeesPerLiquidity memory rewardRates = poolRewardRates[poolId];

            while (state.lastVirtualOrderExecutionTime != currentTime) {
                (uint32 nextTime, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(
                    state.lastVirtualOrderExecutionTime, currentTime
                );

                uint32 timeElapsed = nextTime - state.lastVirtualOrderExecutionTime;

                if (state.saleRateToken0 != 0 && state.saleRateToken1 != 0) {
                    (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(poolId);
                    SqrtRatio sqrtRatioNext = computeNextSqrtRatio({
                        sqrtRatio: sqrtRatio,
                        liquidity: liquidity,
                        saleRateToken0: state.saleRateToken0,
                        saleRateToken1: state.saleRateToken1,
                        timeElapsed: timeElapsed,
                        fee: poolKey.fee()
                    });
                } else if (state.saleRateToken0 != 0 || state.saleRateToken1 != 0) {
                    if (state.saleRateToken0 != 0) {
                        // sell token0
                    } else {
                        // sell token1
                    }
                }

                if (initialized) {
                    poolRewardRatesBefore[poolId][nextTime] = rewardRates;

                    TimeInfo memory timeInfo = poolTimeInfos[poolId][nextTime];

                    // todo: we need to figure out how to handle overflow here

                    state.saleRateToken0 = SafeCastLib.toUint112(
                        uint256(int256(uint256(state.saleRateToken0)) + timeInfo.saleRateDeltaToken0)
                    );
                    state.saleRateToken1 = SafeCastLib.toUint112(
                        uint256(int256(uint256(state.saleRateToken1)) + timeInfo.saleRateDeltaToken1)
                    );

                    // this time is _consumed_, will never be crossed again, so we delete the info we no longer need.
                    // this helps reduce the cost of executing virtual orders.
                    delete poolTimeInfos[poolId][nextTime];
                    poolInitializedTimesBitmap[poolId].flipTime(nextTime);
                }
            }

            _emitVirtualOrdersExecuted(poolId, state.saleRateToken0, state.saleRateToken1);
        }
    }

    ///////////////////////// Extension call points /////////////////////////

    function afterInitializePool(address, PoolKey memory key, int32, SqrtRatio) external override onlyCore {
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();

        bytes32 poolId = key.toPoolId();
        poolState[poolId] = PoolState(uint32(block.timestamp), 0, 0);
        _emitVirtualOrdersExecuted(poolId, 0, 0);
    }

    function beforeSwap(address, PoolKey memory poolKey, int128, bool, SqrtRatio, uint256) external override onlyCore {
        _executeVirtualOrders(poolKey);
    }

    function beforeUpdatePosition(address, PoolKey memory poolKey, UpdatePositionParameters memory)
        external
        override
        onlyCore
    {
        _executeVirtualOrders(poolKey);
    }
}
