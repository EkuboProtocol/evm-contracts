// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {TWAMMLib} from "../libraries/TWAMMLib.sol";
import {TWAMM} from "../extensions/TWAMM.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {MAX_NUM_VALID_TIMES} from "../math/time.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

function getAllValidTimes(uint256 currentTime) pure returns (uint256[] memory times) {
    unchecked {
        times = new uint256[](MAX_NUM_VALID_TIMES);
        uint256 count = 0;
        uint256 stepSize = 16;
        uint256 t = ((currentTime / stepSize) * stepSize) + stepSize;

        while (true) {
            times[count++] = t;

            uint256 n = t + stepSize;
            stepSize = uint256(1) << FixedPointMathLib.max(4, (((LibBit.fls(n - currentTime)) / 4) * 4));

            t = ((n + (stepSize - 1)) / stepSize) * stepSize;

            if (t - currentTime > type(uint32).max) {
                break;
            }
        }

        assembly ("memory-safe") {
            mstore(times, count)
        }
    }
}

struct TimeSaleRateInfo {
    uint256 time;
    int112 saleRateDelta0;
    int112 saleRateDelta1;
}

struct PoolState {
    SqrtRatio sqrtRatio;
    int32 tick;
    uint128 liquidity;
    uint256 lastVirtualOrderExecutionTime;
    uint112 saleRateToken0;
    uint112 saleRateToken1;
    TimeSaleRateInfo[] saleRateDeltas;
}

contract TWAMMDataFetcher is UsesCore {
    using CoreLib for *;
    using TWAMMLib for *;

    TWAMM public immutable twamm;

    constructor(ICore core, TWAMM _twamm) UsesCore(core) {
        twamm = _twamm;
    }

    function getPoolState(PoolKey memory poolKey) public view returns (PoolState memory state) {
        unchecked {
            (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(poolKey.toPoolId());
            (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1) =
                twamm.poolState(poolKey.toPoolId());

            uint256 lastTimeReal = block.timestamp - (uint32(block.timestamp) - lastVirtualOrderExecutionTime);

            uint256[] memory allValidTimes = getAllValidTimes(lastTimeReal);

            // todo: look up all valid times

            state = PoolState({
                sqrtRatio: sqrtRatio,
                tick: tick,
                liquidity: liquidity,
                lastVirtualOrderExecutionTime: lastTimeReal,
                saleRateToken0: saleRateToken0,
                saleRateToken1: saleRateToken1,
                saleRateDeltas: new TimeSaleRateInfo[](0)
            });
        }
    }

    function executeVirtualOrdersAndGetPoolState(PoolKey memory poolKey) public returns (PoolState memory state) {
        twamm.lockAndExecuteVirtualOrders(poolKey);
        state = getPoolState(poolKey);
    }
}
