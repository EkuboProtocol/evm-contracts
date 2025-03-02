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
import {findNextInitializedTime, flipTime} from "../math/timeBitmap.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";

function twammCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: true,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

using {orderId} for OrderKey global;

struct OrderKey {
    address sellToken;
    address buyToken;
    // todo: these could take up as few as 32+64+64=160 bits
    uint64 fee;
    uint256 startTime;
    uint256 endTime;
}

function orderId(OrderKey memory orderKey) pure returns (bytes32 id) {
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
    using {findNextInitializedTime, flipTime} for mapping(uint256 word => Bitmap bitmap);
    using CoreLib for ICore;

    error TickSpacingMustBeMaximum();

    struct OrdersState {
        uint32 lastVirtualOrderExecutionTime;
        // 80.32 numbers, meaning the maximum amount of either token sold per second is 1.2089258196E24
        uint112 saleRateToken0;
        uint112 saleRateToken1;
    }

    struct OrderData {
        // the current sale rate of the order
        uint112 saleRate;
        // amount that has already been withdrawn
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

    mapping(bytes32 poolId => OrdersState) private ordersState;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) private initializedTimesBitmap;
    mapping(bytes32 poolId => mapping(uint32 time => TimeInfo)) private timeInfos;

    // The global reward rate and the reward rate before a given time are both used to
    mapping(bytes32 poolId => FeesPerLiquidity) private rewardRates;
    mapping(bytes32 poolId => mapping(uint32 time => FeesPerLiquidity)) private rewardRatesBefore;

    // Data for the individual orders
    mapping(address owner => mapping(bytes32 salt => mapping(bytes32 orderId => OrderData))) private orderData;

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

    function _executeVirtualOrders(PoolKey memory poolKey) internal {
        bytes32 poolId = poolKey.toPoolId();
        OrdersState memory state = ordersState[poolId];

        uint32 time = state.lastVirtualOrderExecutionTime;

        uint32 currentTime = uint32(block.timestamp);

        if (time != currentTime) {
            while (time != currentTime) {
                (uint32 nextTime, bool initialized) = initializedTimesBitmap[poolId].findNextInitializedTime(time);
                // remember* we have to clear the order info slots as advance time!
                // this saves gas and also means people can have orders up to max uint32 duration since it will never wrap
            }

            _emitVirtualOrdersExecuted(poolId, state.saleRateToken0, state.saleRateToken1);
        }
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
        } else if (callType == 1) {
            (, CollectProceedsParams memory params) = abi.decode(data, (uint256, CollectProceedsParams));
        } else {
            revert();
        }
    }

    // Only happens as part of a swap in execute virtual orders
    function handleLockData(uint256 id, bytes memory data) internal override returns (bytes memory result) {}

    ///////////////////////// Extension call points /////////////////////////

    function beforeInitializePool(address, PoolKey memory key, int32) external view override onlyCore {
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();
    }

    function afterInitializePool(address, PoolKey memory key, int32, SqrtRatio) external override onlyCore {
        bytes32 poolId = key.toPoolId();
        ordersState[poolId] = OrdersState(uint32(block.timestamp), 0, 0);
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
