// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "../FullTest.sol";
import {QuoteData, QuoteDataFetcher} from "../../src/lens/QuoteDataFetcher.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {TestToken} from "../TestToken.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, MAX_TICK_SPACING} from "../../src/math/constants.sol";
import {Bounds} from "../../src/types/positionKey.sol";

contract QuoteDataFetcherTest is FullTest {
    QuoteDataFetcher internal qdf;

    function setUp() public override {
        FullTest.setUp();
        qdf = new QuoteDataFetcher(core);
    }

    function test_getQuoteData() public {
        PoolKey memory poolKey = createPool(0, 0, 1);
        (, uint128 liqA) = createPosition(poolKey, Bounds(-50, 50), 100, 100);
        (, uint128 liqB) = createPosition(poolKey, Bounds(-2000, 1200), 100, 100);
        (, uint128 liqC) = createPosition(poolKey, Bounds(-400, -200), 0, 100);
        (, uint128 liqD) = createPosition(poolKey, Bounds(250, 600), 100, 0);

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = poolKey;
        QuoteData[] memory qd = qdf.getQuoteData(keys, 2);
        assertEq(qd.length, 1);
        assertEq(qd[0].liquidity, liqA + liqB);
        assertEq(qd[0].sqrtRatio, uint256(1) << 128);
        assertEq(qd[0].tick, 0);
        assertEq(qd[0].ticks.length, 5);
        assertEq(qd[0].ticks[0].number, -400);
        assertEq(qd[0].ticks[1].number, -200);
        assertEq(qd[0].ticks[2].number, -50);
        assertEq(qd[0].ticks[3].number, 50);
        assertEq(qd[0].ticks[4].number, 250);

        assertEq(qd[0].ticks[0].liquidityDelta, int128(liqC));
        assertEq(qd[0].ticks[1].liquidityDelta, -int128(liqC));
        assertEq(qd[0].ticks[2].liquidityDelta, int128(liqA));
        assertEq(qd[0].ticks[3].liquidityDelta, -int128(liqA));
        assertEq(qd[0].ticks[4].liquidityDelta, int128(liqD));
    }
}
