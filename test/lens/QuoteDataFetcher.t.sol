// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "../FullTest.sol";
import {QuoteData, QuoteDataFetcher} from "../../src/lens/QuoteDataFetcher.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {TestToken} from "../TestToken.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {
    MIN_TICK,
    MAX_TICK,
    NATIVE_TOKEN_ADDRESS,
    MAX_TICK_SPACING,
    FULL_RANGE_ONLY_TICK_SPACING
} from "../../src/math/constants.sol";
import {Bounds} from "../../src/types/positionKey.sol";

contract QuoteDataFetcherTest is FullTest {
    QuoteDataFetcher internal qdf;

    function setUp() public override {
        FullTest.setUp();
        qdf = new QuoteDataFetcher(core);
    }

    function test_getQuoteData() public {
        PoolKey memory poolKey = createPool({tick: 10, fee: 0, tickSpacing: 5});
        (, uint128 liqA) = createPosition(poolKey, Bounds(-50, 50), 500, 500);
        (, uint128 liqB) = createPosition(poolKey, Bounds(-2000, 1200), 1000, 1000);
        (, uint128 liqC) = createPosition(poolKey, Bounds(-400, -200), 0, 300);
        (, uint128 liqD) = createPosition(poolKey, Bounds(250, 600), 200, 0);
        createPosition(poolKey, Bounds(-1280, -1275), 0, 5000);

        PoolKey memory poolKeyFull = createPool({tick: 693147, fee: 0, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING});
        (, uint128 liqF) = createPosition(poolKeyFull, Bounds(MIN_TICK, MAX_TICK), 5000, 5000);
        (, uint128 liqG) = createPosition(poolKeyFull, Bounds(MIN_TICK, MAX_TICK), 7500, 7500);

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = poolKey;
        keys[1] = poolKeyFull;
        QuoteData[] memory qd = qdf.getQuoteData(keys, 1);
        assertEq(qd.length, 2);
        assertEq(qd[0].liquidity, liqA + liqB);
        assertEq(qd[0].sqrtRatio, tickToSqrtRatio(10));
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
        assertEq(qd[1].sqrtRatio, tickToSqrtRatio(693147));
        assertEq(qd[1].minTick, MIN_TICK);
        assertEq(qd[1].maxTick, MAX_TICK);
        assertEq(qd[1].tick, 693147);
        assertEq(qd[1].ticks.length, 0);
    }
}
