// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, toConfig} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PositionKey, Bounds} from "../types/positionKey.sol";
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
import {calculateNextSqrtRatio} from "../math/twamm.sol";

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

contract TWAMM is ExposedStorage, BaseExtension, BaseForwardee, BaseLocker {
    using {searchForNextInitializedTime, flipTime} for mapping(uint256 word => Bitmap bitmap);
    using CoreLib for ICore;

    error TickSpacingMustBeMaximum();

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

    mapping(bytes32 poolId => PoolState) private poolState;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) private poolInitializedTimesBitmap;
    mapping(bytes32 poolId => mapping(uint32 time => TimeInfo)) private poolTimeInfos;

    // The global reward rate and the reward rate before a given time are both used to
    mapping(bytes32 poolId => FeesPerLiquidity) private poolRewardRates;
    mapping(bytes32 poolId => mapping(uint32 time => FeesPerLiquidity)) private poolRewardRatesBefore;

    // Current state of each individual order
    mapping(address owner => mapping(bytes32 salt => mapping(bytes32 orderId => OrderState))) private orderState;

    constructor(ICore core) BaseLocker(core) BaseExtension(core) BaseForwardee(core) {}

    function getPoolKey(address token0, address token1, uint64 fee) external view returns (PoolKey memory) {
        return PoolKey({
            token0: token0,
            token1: token1,
            config: toConfig({_fee: fee, _tickSpacing: FULL_RANGE_ONLY_TICK_SPACING, _extension: address(this)})
        });
    }

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
        lock(abi.encode(poolKey));
    }

    // Must be called on a pool that is executed up to the current timestamp
    function _getOrderInfo(address owner, bytes32 salt, OrderKey memory orderKey)
        internal
        view
        returns (uint112 saleRate, uint256 rewardRateSnapshot, uint128 purchasedAmount)
    {
        // todo: implement
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return twammCallPoints();
    }

    ///////////////////////// Callbacks /////////////////////////

    function handleForwardData(uint256 id, address originalLocker, bytes memory data)
        internal
        override
        returns (bytes memory result)
    {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == 0) {
            (, UpdateSaleRateParams memory params) = abi.decode(data, (uint256, UpdateSaleRateParams));

            _executeVirtualOrdersFromWithinLock(_orderKeyToPoolKey(params.orderKey));
        } else if (callType == 1) {
            (, CollectProceedsParams memory params) = abi.decode(data, (uint256, CollectProceedsParams));

            _executeVirtualOrdersFromWithinLock(_orderKeyToPoolKey(params.orderKey));
        } else {
            revert();
        }
    }

    function _orderKeyToPoolKey(OrderKey memory orderKey) internal returns (PoolKey memory poolKey) {
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

    // Only happens as part of a swap in execute virtual orders
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        unchecked {
            PoolKey memory poolKey = abi.decode(data, (PoolKey));

            _executeVirtualOrdersFromWithinLock(poolKey);
        }
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
                    SqrtRatio sqrtRatioNext = calculateNextSqrtRatio({
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
