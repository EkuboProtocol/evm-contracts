// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {PriceFetcher, getTimestampsForPeriod} from "../../src/lens/PriceFetcher.sol";
import {PoolKey} from "../../src/types/keys.sol";
import {TestToken} from "../TestToken.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/ticks.sol";
import {Bounds} from "../../src/types/keys.sol";

contract PriceFetcherTest is BaseOracleTest {
    PriceFetcher internal pf;

    function setUp() public override {
        BaseOracleTest.setUp();
        pf = new PriceFetcher(oracle);
    }

    function test_getTimestampsForPeriod() public pure {
        uint64[] memory result = getTimestampsForPeriod({endTime: 100, numIntervals: 7, period: 5});
        assertEq(result.length, 7);
        assertEq(result[0], 70);
        assertEq(result[1], 75);
        assertEq(result[2], 80);
        assertEq(result[3], 85);
        assertEq(result[4], 90);
        assertEq(result[5], 95);
        assertEq(result[6], 100);
    }

    function test_fetchPrices_gas_snapshot() public {
        createOraclePool(address(token0), 0);
        updateOraclePoolLiquidity(address(token0), 500);
        advanceTime(30);

        address[] memory baseTokens = new address[](1);
        baseTokens[0] = address(token0);
        pf.getPricesInOracleToken(30, baseTokens);
        vm.snapshotGasLastCall("getPricesInOracleToken(1 token)");
    }

    function test_canFetchPrices() public {
        createOraclePool(address(token0), 3737671);

        advanceTime(15);

        createOraclePool(address(token1), -4234108);

        updateOraclePoolLiquidity(address(token0), 500);
        updateOraclePoolLiquidity(address(token1), 7500);

        advanceTime(30);
        address[] memory baseTokens = new address[](4);
        baseTokens[0] = address(token0);
        baseTokens[1] = address(token1);
        baseTokens[2] = address(oracleToken);
        baseTokens[3] = address(0xdeadbeef);
        (address ot, PriceFetcher.Result[] memory results) = pf.getPricesInOracleToken(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].priceX128, 8101965063774199046946818765421275446);
        assertEq(results[0].liquidity, 500);

        // ~= 69
        assertEq(results[1].priceX128, 23479468721532054986745577134847629670150);
        assertEq(results[1].liquidity, 7500);

        assertEq(results[2].priceX128, 1 << 128);
        assertEq(results[2].liquidity, type(uint128).max);

        assertEq(results[3].priceX128, 0);
        assertEq(results[3].liquidity, 0);

        address nt = address(new TestToken(address(this)));
        createOraclePool(nt, 11512931);
        updateOraclePoolLiquidity(nt, 100000);

        updateOraclePoolLiquidity(address(token0), 5000);
        updateOraclePoolLiquidity(address(token1), 2500);

        advanceTime(15);

        baseTokens = new address[](5);
        baseTokens[0] = address(token0);
        baseTokens[1] = address(token1);
        baseTokens[2] = address(oracleToken);
        baseTokens[3] = address(0xdeadbeef);
        baseTokens[4] = nt;

        (ot, results) = pf.getPricesInOracleToken(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].priceX128, 8101965063774199046946818765421275446);
        // went up by not a lot
        assertEq(results[0].liquidity, 909);

        // ~= 69
        assertEq(results[1].priceX128, 23479468721532054986745577134847629670150);
        // went down by half
        assertEq(results[1].liquidity, 3750);

        assertEq(results[2].priceX128, 1 << 128);
        assertEq(results[2].liquidity, type(uint128).max);

        // insufficient history
        assertEq(results[3].priceX128, 0);
        assertEq(results[3].liquidity, 0);
    }

    function test_getAverageMultihop() public {
        uint64 startTime = uint64(block.timestamp);
        // 2 ETH / token0
        PoolKey memory poolKey0 =
            createPool(address(oracleToken), address(token0), -693147, 0, MAX_TICK_SPACING, address(oracle));
        // 0.25 ETH / token1
        PoolKey memory poolKey1 =
            createPool(address(oracleToken), address(token1), 693147 * 2, 0, MAX_TICK_SPACING, address(oracle));

        createPosition(poolKey0, Bounds(MIN_TICK, MAX_TICK), 2000, 1000); // ~1414
        createPosition(poolKey1, Bounds(MIN_TICK, MAX_TICK), 3000, 12000); // ~6000

        advanceTime(12);

        // to 1 ETH / token0, meaning more token0 is sold into the pool
        movePrice(poolKey0, 0);
        // to 0.004 ETH / token1, meaning much more token1 is sold into the pool
        movePrice(poolKey1, 693147 * 8);

        advanceTime(12);

        // first 12 seconds the token1/token0 price is 1 token1 / 8 token0
        (uint128 liquidity, int32 tick) =
            pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 12);
        // combined should be about sqrt(1000*12000) = ~3464
        assertEq(liquidity, 3461);
        assertEq(tick, -2079441); // ~= 1/8

        // first half of first period is the same
        (liquidity, tick) = pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 6);
        assertEq(liquidity, 3461);
        assertEq(tick, -2079441);

        // liquidity goes up considerably because token0 and token1 are sold into the pools
        (liquidity, tick) = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 6, startTime + 18);
        assertEq(liquidity, 6352);
        assertEq(tick, -3812308); // ~= 0.022097162025342

        // second period
        (liquidity, tick) = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 12, startTime + 24);
        assertEq(liquidity, 11645);
        assertEq(tick, -5545176); // ~= 1.000001^(-5545176) ~= 0.003906266472948

        // second half of second period
        (liquidity, tick) = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 18, startTime + 24);
        assertEq(liquidity, 11645);
        assertEq(tick, -5545176);

        pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 24);
        vm.snapshotGasLastCall("getAveragesOverPeriod");
    }
}
