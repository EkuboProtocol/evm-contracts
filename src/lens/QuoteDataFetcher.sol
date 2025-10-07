// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {DynamicArrayLib} from "solady/utils/DynamicArrayLib.sol";
import {PoolId} from "../types/poolId.sol";

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
    // all the initialized ticks within minBitmapsSearched of the current tick
    TickDelta[] ticks;
}

// Returns useful data for a pool for computing off-chain quotes
contract QuoteDataFetcher is UsesCore {
    using CoreLib for *;
    using DynamicArrayLib for *;

    constructor(ICore core) UsesCore(core) {}

    /// @param minBitmapsSearched indicates the minimum number of initialized tick bitmaps the current tick should be searched for tick data
    /// @dev We use the unit of bitmaps (i.e. tickSpacings * 256) because that's a rough approximation of how the gas cost of this function scales
    function getQuoteData(PoolKey[] calldata poolKeys, uint32 minBitmapsSearched)
        external
        view
        returns (QuoteData[] memory results)
    {
        unchecked {
            results = new QuoteData[](poolKeys.length);
            for (uint256 i = 0; i < poolKeys.length; i++) {
                PoolId poolId = poolKeys[i].toPoolId();
                (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = CORE.poolState(poolId).parse();

                if (!sqrtRatio.isZero()) {
                    int256 minTick;
                    int256 maxTick;
                    TickDelta[] memory ticks;
                    // For concentrated liquidity pools, search tick bitmaps
                    if (!poolKeys[i].isStableswap()) {
                        int256 rangeSize =
                            int256(uint256(minBitmapsSearched)) * int256(uint256(poolKeys[i].tickSpacing())) * 256;
                        minTick = int256(tick) - rangeSize;
                        maxTick = int256(tick) + rangeSize;

                        if (minTick < MIN_TICK) {
                            minTick = MIN_TICK;
                        }
                        if (maxTick > MAX_TICK) {
                            maxTick = MAX_TICK;
                        }
                        ticks = _getInitializedTicksInRange(
                            poolId, int32(minTick), int32(maxTick), poolKeys[i].tickSpacing()
                        );
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
                } else {
                    results[i] = QuoteData({
                        tick: tick,
                        sqrtRatio: sqrtRatio,
                        liquidity: liquidity,
                        minTick: MIN_TICK,
                        maxTick: MAX_TICK,
                        ticks: new TickDelta[](0)
                    });
                }
            }
        }
    }

    // Returns all the initialized ticks and the liquidity delta of each tick in the given range
    function _getInitializedTicksInRange(PoolId poolId, int32 fromTick, int32 toTick, uint32 tickSpacing)
        internal
        view
        returns (TickDelta[] memory ticks)
    {
        assert(toTick >= fromTick);

        // For concentrated liquidity pools, search tick bitmaps
        if (!poolKey.isStableswap()) {
            DynamicArrayLib.DynamicArray memory packedTicks;

            while (toTick >= fromTick) {
                (int32 tick, bool initialized) = CORE.prevInitializedTick(
                    poolId, toTick, tickSpacing, uint256(uint32(toTick - fromTick)) / (uint256(tickSpacing) * 256)
                );

                if (initialized && tick >= fromTick) {
                    (int128 liquidityDelta,) = CORE.poolTicks(poolId, tick);
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
        return _getInitializedTicksInRange(poolKey.toPoolId(), fromTick, toTick, poolKey.tickSpacing());
    }
}
