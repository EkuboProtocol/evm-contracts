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
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

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
                address(twamm).staticcall(abi.encodePacked(IExposedStorage.sload.selector, timeInfoSlots));

            assert(success);

            uint256 countNonZero = 0;
            TimeSaleRateInfo[] memory saleRateDeltas = new TimeSaleRateInfo[](timeInfoSlots.length);

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                //         // the number of orders referencing this timestamp. If non-zero, then the time is initialized.
                // uint32 numOrders;
                // // the change of sale rate for token0 at this time
                // int112 saleRateDeltaToken0;
                // // the change of sale rate for token1 at this time
                // int112 saleRateDeltaToken1;
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
        twamm.lockAndExecuteVirtualOrders(poolKey);
        state = getPoolState(poolKey);
    }
}
