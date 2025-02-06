// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {Position} from "../types/position.sol";

struct TickDelta {
    int32 number;
    int128 liquidityDelta;
}

struct QuoteData {
    int32 tick;
    uint256 sqrtRatio;
    uint128 liquidity;
    // all initialized ticks that are <= the current tick up to minTickSpacings
    TickDelta[] prevTicks;
    // all initialized ticks that are > the current tick up to minTickSpacings
    TickDelta[] nextTicks;
}

// Returns useful data for a pool for computing off-chain quotes
contract QuoteDataFetcher is UsesCore {
    using CoreLib for *;

    constructor(ICore core) UsesCore(core) {}

    function getQuoteData(PoolKey[] calldata poolKeys, uint32 minTickSpacings)
        external
        returns (QuoteData[] memory results)
    {
        unchecked {
            results = new QuoteData[](poolKeys.length);
            for (uint256 i = 0; i < poolKeys.length; i++) {
                bytes32 poolId = poolKeys[i].toPoolId();
                (uint256 sqrtRatio, int32 tick) = core.poolPrice(poolId);
                uint128 liquidity = core.poolLiquidity(poolId);
                TickDelta[] memory prevTicks = _prevInitializedTicks(poolId, tick, minTickSpacings);
                TickDelta[] memory nextTicks = _nextInitializedTicks(poolId, tick, minTickSpacings);

                results[i] = QuoteData({
                    tick: tick,
                    sqrtRatio: sqrtRatio,
                    liquidity: liquidity,
                    prevTicks: prevTicks,
                    nextTicks: nextTicks
                });
            }
        }
    }

    function _prevInitializedTicks(bytes32 poolId, int32 fromTick, uint32 minTickSpacings)
        internal
        returns (TickDelta[] memory ticks)
    {}

    function prevInitializedTicks(PoolKey calldata poolKey, int32 fromTick, uint32 minTickSpacings)
        public
        returns (TickDelta[] memory ticks)
    {
        ticks = _prevInitializedTicks(poolKey.toPoolId(), fromTick, minTickSpacings);
    }

    function _nextInitializedTicks(bytes32 poolId, int32 fromTick, uint32 minTickSpacings)
        internal
        returns (TickDelta[] memory ticks)
    {}

    function nextInitializedTicks(PoolKey calldata poolKey, int32 fromTick, uint32 minTickSpacings)
        public
        returns (TickDelta[] memory ticks)
    {
        ticks = _nextInitializedTicks(poolKey.toPoolId(), fromTick, minTickSpacings);
    }
}
