// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {TWAMMLib} from "../libraries/TWAMMLib.sol";
import {TWAMM} from "../extensions/TWAMM.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {MAX_NUM_VALID_TIMES, nextValidTime} from "../math/time.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

function getAllValidFutureTimes(uint256 currentTime) pure returns (uint256[] memory times) {
    unchecked {
        times = new uint256[](MAX_NUM_VALID_TIMES);
        uint256 count = 0;
        uint256 t = currentTime;

        while (true) {
            t = nextValidTime(currentTime, t);
            if (t == 0) break;
            times[count++] = t;
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

    TWAMM public immutable TWAMM_EXTENSION;

    constructor(ICore core, TWAMM _twamm) UsesCore(core) {
        TWAMM_EXTENSION = _twamm;
    }

    function getPoolState(PoolKey memory poolKey) public view returns (PoolState memory state) {
        unchecked {
            (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = CORE.poolState(poolKey.toPoolId()).parse();
            (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1) =
                TWAMM_EXTENSION.poolState(poolKey.toPoolId());

            uint256 lastTimeReal = block.timestamp - (uint32(block.timestamp) - lastVirtualOrderExecutionTime);

            uint256[] memory allValidTimes = getAllValidFutureTimes(lastTimeReal);

            bytes32 poolId = poolKey.toPoolId();
            bytes32[] memory timeInfoSlots = new bytes32[](allValidTimes.length);
            assembly ("memory-safe") {
                mstore(0, poolId)
                mstore(32, 2)
                mstore(32, keccak256(0, 64))
                for { let i := 0 } lt(i, mload(timeInfoSlots)) { i := add(i, 1) } {
                    let offset := mul(add(i, 1), 32)
                    mstore(0, mload(add(allValidTimes, offset)))
                    mstore(add(timeInfoSlots, offset), keccak256(0, 64))
                }
            }

            (bool success, bytes memory result) =
                address(TWAMM_EXTENSION).staticcall(abi.encodePacked(IExposedStorage.sload.selector, timeInfoSlots));

            assert(success);

            uint256 countNonZero = 0;
            TimeSaleRateInfo[] memory saleRateDeltas = new TimeSaleRateInfo[](timeInfoSlots.length);

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                uint32 numOrders;
                int112 saleRateDeltaToken0;
                int112 saleRateDeltaToken1;
                assembly ("memory-safe") {
                    let value := mload(add(result, mul(add(i, 1), 32)))
                    numOrders := and(value, 0xffffffff)
                    saleRateDeltaToken0 := and(shr(32, value), 0xffffffffffffffffffffffffffff)
                    saleRateDeltaToken1 := shr(144, value)
                }

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
