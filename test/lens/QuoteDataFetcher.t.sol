// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {FullTest} from "../FullTest.sol";
import {QuoteData, QuoteDataFetcher} from "../../src/lens/QuoteDataFetcher.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createConcentratedPoolConfig, PoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";

contract QuoteDataFetcherTest is FullTest {
    QuoteDataFetcher internal qdf;

    function setUp() public override {
        FullTest.setUp();
        qdf = new QuoteDataFetcher(core);
    }

    function test_getQuoteData() public {
        PoolKey memory poolKey = createPool({tick: 10, fee: 0, tickSpacing: 5});
        (, uint128 liqA) = createPosition(poolKey, -50, 50, 500, 500);
        (, uint128 liqB) = createPosition(poolKey, -2000, 1200, 1000, 1000);
        (, uint128 liqC) = createPosition(poolKey, -400, -200, 0, 300);
        (, uint128 liqD) = createPosition(poolKey, 250, 600, 200, 0);
        createPosition(poolKey, -1280, -1275, 0, 5000);

        PoolKey memory poolKeyFull = createFullRangePool({tick: 693147, fee: 0});
        (, uint128 liqF) = createPosition(poolKeyFull, MIN_TICK, MAX_TICK, 5000, 5000);
        (, uint128 liqG) = createPosition(poolKeyFull, MIN_TICK, MAX_TICK, 7500, 7500);

        PoolConfig poolConfigStable =
            createStableswapPoolConfig({_fee: 100, _extension: address(0), _centerTick: 693147, _amplification: 8});
        PoolKey memory poolKeyStable =
            createPool({_token0: address(token0), _token1: address(token1), tick: 693147 * 2, config: poolConfigStable});
        (int32 lowerTickStable, int32 upperTickStable) = poolConfigStable.stableswapActiveLiquidityTickRange();
        (, uint128 liqH) = createPosition(poolKeyStable, lowerTickStable, upperTickStable, 10000, 6000);
        (, uint128 liqI) = createPosition(poolKeyStable, lowerTickStable, upperTickStable, 2000, 15000);

        PoolKey memory poolKeyNoLiquidity = createPool({tick: -693147, fee: 0, tickSpacing: 100});
        PoolKey memory poolKeyDoesNotExist =
            PoolKey(address(token0), address(token1), createConcentratedPoolConfig(1, 1, address(0)));

        PoolKey[] memory keys = new PoolKey[](5);
        keys[0] = poolKey;
        keys[1] = poolKeyFull;
        keys[2] = poolKeyNoLiquidity;
        keys[3] = poolKeyDoesNotExist;
        keys[4] = poolKeyStable;
        QuoteData[] memory qd = qdf.getQuoteData(keys, 1);
        assertEq(qd.length, 5);

        assertEq(qd[0].liquidity, liqA + liqB);
        assertTrue(qd[0].sqrtRatio == tickToSqrtRatio(10));
        assertEq(qd[0].minTick, -1270);
        assertEq(qd[0].maxTick, 1290);
        assertEq(qd[0].tick, 10);
        assertEq(qd[0].ticks.length, 7);
        assertEq(qd[0].ticks[0].number, -400);
        assertEq(qd[0].ticks[1].number, -200);
        assertEq(qd[0].ticks[2].number, -50);
        assertEq(qd[0].ticks[3].number, 50);
        assertEq(qd[0].ticks[4].number, 250);
        assertEq(qd[0].ticks[5].number, 600);
        assertEq(qd[0].ticks[6].number, 1200);

        assertEq(qd[0].ticks[0].liquidityDelta, int128(liqC));
        assertEq(qd[0].ticks[1].liquidityDelta, -int128(liqC));
        assertEq(qd[0].ticks[2].liquidityDelta, int128(liqA));
        assertEq(qd[0].ticks[3].liquidityDelta, -int128(liqA));
        assertEq(qd[0].ticks[4].liquidityDelta, int128(liqD));
        assertEq(qd[0].ticks[5].liquidityDelta, -int128(liqD));
        assertEq(qd[0].ticks[6].liquidityDelta, -int128(liqB));

        assertEq(qd[1].liquidity, liqF + liqG);
        assertTrue(qd[1].sqrtRatio == tickToSqrtRatio(693147));
        assertEq(qd[1].minTick, MIN_TICK);
        assertEq(qd[1].maxTick, MAX_TICK);
        assertEq(qd[1].tick, 693147);
        assertEq(qd[1].ticks.length, 2);
        assertEq(qd[1].ticks[0].number, MIN_TICK);
        assertEq(qd[1].ticks[0].liquidityDelta, int128(liqF + liqG));
        assertEq(qd[1].ticks[1].number, MAX_TICK);
        assertEq(qd[1].ticks[1].liquidityDelta, -int128(liqF + liqG));

        assertEq(qd[2].liquidity, 0);
        assertTrue(qd[2].sqrtRatio == tickToSqrtRatio(-693147));
        assertEq(qd[2].minTick, -718747);
        assertEq(qd[2].maxTick, -667547);
        assertEq(qd[2].tick, -693147);
        assertEq(qd[2].ticks.length, 0);

        assertEq(qd[3].liquidity, 0);
        assertEq(SqrtRatio.unwrap(qd[3].sqrtRatio), 0);
        assertEq(qd[3].minTick, MIN_TICK);
        assertEq(qd[3].maxTick, MAX_TICK);
        assertEq(qd[3].tick, 0);
        assertEq(qd[3].ticks.length, 0);

        assertEq(qd[4].liquidity, liqH + liqI);
        assertTrue(qd[4].sqrtRatio == tickToSqrtRatio(693147 * 2));
        assertEq(qd[4].minTick, MIN_TICK);
        assertEq(qd[4].maxTick, MAX_TICK);
        assertEq(qd[4].tick, 693147 * 2);
        assertEq(qd[4].ticks.length, 2);
        assertEq(qd[4].ticks[0].number, lowerTickStable);
        assertEq(qd[4].ticks[0].liquidityDelta, int128(liqH + liqI));
        assertEq(qd[4].ticks[1].number, upperTickStable);
        assertEq(qd[4].ticks[1].liquidityDelta, -int128(liqH + liqI));
    }
}
