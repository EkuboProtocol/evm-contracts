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
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

function twammCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

contract TWAMM is ExposedStorage, BaseExtension, BaseForwardee {
    error TickSpacingMustBeMaximum();

    using CoreLib for ICore;

    struct PoolState {
        uint32 lastVirtualOrderExecutionTime;
        // 80.32 numbers, meaning the maximum amount of either token sold per second is 1.2089258196E24
        uint112 saleRateToken0;
        uint112 saleRateToken1;
    }

    mapping(bytes32 poolId => PoolState) private poolState;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function getPoolKey(address token0, address token1, uint64 fee) public view returns (PoolKey memory) {
        return PoolKey({
            token0: token0,
            token1: token1,
            config: toConfig({_fee: fee, _tickSpacing: FULL_RANGE_ONLY_TICK_SPACING, _extension: address(this)})
        });
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return twammCallPoints();
    }

    function handleForwardData(uint256 id, address originalLocker, bytes memory data)
        internal
        override
        returns (bytes memory result)
    {}

    function beforeInitializePool(address, PoolKey memory key, int32) external override onlyCore {
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();

        poolState[key.toPoolId()] = PoolState(uint32(block.timestamp), 0, 0);
    }
}
