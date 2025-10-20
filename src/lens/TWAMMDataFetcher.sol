// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {CoreLib} from "../libraries/CoreLib.sol";
import {TWAMMLib} from "../libraries/TWAMMLib.sol";
import {TWAMM} from "../extensions/TWAMM.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {MAX_NUM_VALID_TIMES, nextValidTime} from "../math/time.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {PoolId} from "../types/poolId.sol";
import {TimeInfo} from "../types/timeInfo.sol";
import {TWAMMStorageLayout} from "../libraries/TWAMMStorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";

function getAllValidFutureTimes(uint64 currentTime) pure returns (uint64[] memory times) {
    unchecked {
        times = new uint64[](MAX_NUM_VALID_TIMES);
        uint256 count = 0;
        uint64 t = currentTime;

        while (true) {
            uint256 nextTime = nextValidTime(currentTime, t);
            if (nextTime == 0 || nextTime > type(uint64).max) break;

            t = uint64(nextTime);
            times[count++] = t;
        }

        assembly ("memory-safe") {
            mstore(times, count)
        }
    }
}

struct TimeSaleRateInfo {
    uint64 time;
    int112 saleRateDelta0;
    int112 saleRateDelta1;
}

struct PoolState {
    SqrtRatio sqrtRatio;
    int32 tick;
    uint128 liquidity;
    uint64 lastVirtualOrderExecutionTime;
    uint112 saleRateToken0;
    uint112 saleRateToken1;
    TimeSaleRateInfo[] saleRateDeltas;
}

contract TWAMMDataFetcher is UsesCore {
    using CoreLib for *;
    using TWAMMLib for *;

    TWAMM public immutable TWAMM_EXTENSION;

    constructor(ICore core, TWAMM _twamm) UsesCore(core) {
        TWAMM_EXTENSION = _twamm;
    }

    function getPoolState(PoolKey memory poolKey) public view returns (PoolState memory state) {
        unchecked {
            (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = CORE.poolState(poolKey.toPoolId()).parse();
            (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1) =
                TWAMM_EXTENSION.poolState(poolKey.toPoolId()).parse();

            uint64 lastTimeReal = uint64(block.timestamp - (uint32(block.timestamp) - lastVirtualOrderExecutionTime));

            uint64[] memory allValidTimes = getAllValidFutureTimes(lastTimeReal);

            PoolId poolId = poolKey.toPoolId();
            StorageSlot[] memory timeInfoSlots = new StorageSlot[](allValidTimes.length);

            for (uint256 i = 0; i < timeInfoSlots.length; i++) {
                timeInfoSlots[i] = TWAMMStorageLayout.poolTimeInfosSlot(poolId, allValidTimes[i]);
            }

            (bool success, bytes memory result) =
                address(TWAMM_EXTENSION).staticcall(abi.encodePacked(IExposedStorage.sload.selector, timeInfoSlots));
            assert(success);

            uint256 countNonZero = 0;
            TimeSaleRateInfo[] memory saleRateDeltas = new TimeSaleRateInfo[](timeInfoSlots.length);

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                TimeInfo timeInfo;
                assembly ("memory-safe") {
                    timeInfo := mload(add(result, mul(add(i, 1), 32)))
                }

                (uint32 numOrders, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1) = timeInfo.parse();

                if (numOrders != 0) {
                    saleRateDeltas[countNonZero++] =
                        TimeSaleRateInfo(allValidTimes[i], saleRateDeltaToken0, saleRateDeltaToken1);
                }
            }

            assembly ("memory-safe") {
                mstore(saleRateDeltas, countNonZero)
            }

            state = PoolState({
                sqrtRatio: sqrtRatio,
                tick: tick,
                liquidity: liquidity,
                lastVirtualOrderExecutionTime: lastTimeReal,
                saleRateToken0: saleRateToken0,
                saleRateToken1: saleRateToken1,
                saleRateDeltas: saleRateDeltas
            });
        }
    }

    function executeVirtualOrdersAndGetPoolState(PoolKey memory poolKey) public returns (PoolState memory state) {
        TWAMM_EXTENSION.lockAndExecuteVirtualOrders(poolKey);
        state = getPoolState(poolKey);
    }
}
