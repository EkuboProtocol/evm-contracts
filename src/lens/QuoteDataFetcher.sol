// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {DynamicArrayLib} from "solady/utils/DynamicArrayLib.sol";

struct TickDelta {
    int32 number;
    int128 liquidityDelta;
}

struct QuoteData {
    int32 tick;
    SqrtRatio sqrtRatio;
    uint128 liquidity;
    int32 minTick;
    int32 maxTick;
    // all the initialized ticks within minTickSpacings of the current tick
    TickDelta[] ticks;
}

// Returns useful data for a pool for computing off-chain quotes
contract QuoteDataFetcher is UsesCore {
    using CoreLib for *;
    using DynamicArrayLib for *;

    constructor(ICore core) UsesCore(core) {}

    function getQuoteData(PoolKey[] calldata poolKeys, uint32 minTickSpacings)
        external
        view
        returns (QuoteData[] memory results)
    {
        unchecked {
            results = new QuoteData[](poolKeys.length);
            for (uint256 i = 0; i < poolKeys.length; i++) {
                bytes32 poolId = poolKeys[i].toPoolId();
                (SqrtRatio sqrtRatio, int32 tick) = core.poolPrice(poolId);
                uint128 liquidity = core.poolLiquidity(poolId);

                int256 minTick;
                int256 maxTick;
                TickDelta[] memory ticks;
                if (poolKeys[i].tickSpacing != FULL_RANGE_ONLY_TICK_SPACING) {
                    int256 rangeSize = int256(uint256(minTickSpacings)) * int256(uint256(poolKeys[i].tickSpacing)) * 256;
                    minTick = int256(tick) - rangeSize;
                    maxTick = int256(tick) + rangeSize;

                    if (minTick < MIN_TICK) {
                        minTick = MIN_TICK;
                    }
                    if (maxTick > MAX_TICK) {
                        maxTick = MAX_TICK;
                    }
                    ticks = _getInitializedTicksInRange(poolId, int32(minTick), int32(maxTick), poolKeys[i].tickSpacing);
                } else {
                    minTick = MIN_TICK;
                    maxTick = MAX_TICK;
                }

                results[i] = QuoteData({
                    tick: tick,
                    sqrtRatio: sqrtRatio,
                    liquidity: liquidity,
                    minTick: int32(minTick),
                    maxTick: int32(maxTick),
                    ticks: ticks
                });
            }
        }
    }

    // Returns all the initialized ticks and the liquidity delta of each tick in the given range
    function _getInitializedTicksInRange(bytes32 poolId, int32 fromTick, int32 toTick, uint32 tickSpacing)
        internal
        view
        returns (TickDelta[] memory ticks)
    {
        assert(toTick >= fromTick);

        if (tickSpacing != FULL_RANGE_ONLY_TICK_SPACING) {
            DynamicArrayLib.DynamicArray memory packedTicks;

            while (toTick >= fromTick) {
                (int32 tick, bool initialized) = core.prevInitializedTick(
                    poolId, toTick, tickSpacing, uint256(uint32(toTick - fromTick)) / (uint256(tickSpacing) * 256)
                );

                if (initialized && tick >= fromTick) {
                    (int128 liquidityDelta,) = core.poolTicks(poolId, tick);
                    uint256 v;
                    assembly ("memory-safe") {
                        v := or(shl(128, tick), and(liquidityDelta, 0xffffffffffffffffffffffffffffffff))
                    }
                    packedTicks.p(v);
                }

                toTick = tick - 1;
            }

            ticks = new TickDelta[](packedTicks.length());

            uint256 index = 0;

            while (packedTicks.length() > 0) {
                uint256 packed = packedTicks.pop();
                int32 tickNumber;
                int128 liquidityDelta;
                assembly ("memory-safe") {
                    tickNumber := shr(128, packed)
                    liquidityDelta := and(packed, 0xffffffffffffffffffffffffffffffff)
                }
                ticks[index++] = TickDelta(tickNumber, liquidityDelta);
            }
        }
    }

    function getInitializedTicksInRange(PoolKey memory poolKey, int32 fromTick, int32 toTick)
        external
        view
        returns (TickDelta[] memory ticks)
    {
        return _getInitializedTicksInRange(poolKey.toPoolId(), fromTick, toTick, poolKey.tickSpacing);
    }
}
