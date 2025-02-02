// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {
    PriceFetcher, getTimestampsForPeriod, InvalidNumIntervals, InvalidPeriod
} from "../../src/lens/PriceFetcher.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/interfaces/IFlashAccountant.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {TestToken} from "../TestToken.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/constants.sol";
import {Bounds} from "../../src/types/positionKey.sol";

contract PriceFetcherTest is BaseOracleTest {
    PriceFetcher internal pf;

    function setUp() public override {
        BaseOracleTest.setUp();
        pf = new PriceFetcher(oracle);
    }

    function test_getTimestampsForPeriod() public pure {
        uint64[] memory result = getTimestampsForPeriod({endTime: 100, numIntervals: 7, period: 5});
        assertEq(result.length, 8);
        assertEq(result[0], 65);
        assertEq(result[1], 70);
        assertEq(result[2], 75);
        assertEq(result[3], 80);
        assertEq(result[4], 85);
        assertEq(result[5], 90);
        assertEq(result[6], 95);
        assertEq(result[7], 100);
    }

    function test_getTimestampsForPeriod_reverts_invalid() public {
        vm.expectRevert(InvalidPeriod.selector);
        getTimestampsForPeriod({endTime: 100, numIntervals: 7, period: 0});
        vm.expectRevert(InvalidNumIntervals.selector);
        getTimestampsForPeriod({endTime: 100, numIntervals: type(uint32).max, period: 5});
        vm.expectRevert(InvalidNumIntervals.selector);
        getTimestampsForPeriod({endTime: 100, numIntervals: 0, period: 5});
    }

    function test_fetchPrices_gas_snapshot() public {
        createOraclePool(address(token0), 0);
        updateOraclePoolLiquidity(address(token0), 500);
        advanceTime(30);

        address[] memory baseTokens = new address[](1);
        baseTokens[0] = address(token0);
        pf.getOracleTokenAverages(30, baseTokens);
        vm.snapshotGasLastCall("getOracleTokenAverages(1 token)");
    }

    function test_canFetchPrices() public {
        // 42 o / t0
        createOraclePool(address(token0), 3737671);

        advanceTime(15);

        // 0.014492762632609 o / t1
        createOraclePool(address(token1), -4234108);

        updateOraclePoolLiquidity(address(token0), 500);
        updateOraclePoolLiquidity(address(token1), 7500);

        advanceTime(30);
        address[] memory baseTokens = new address[](4);
        baseTokens[0] = address(token0);
        baseTokens[1] = address(token1);
        baseTokens[2] = address(oracleToken);
        baseTokens[3] = address(0xdeadbeef);
        (address ot, PriceFetcher.PeriodAverage[] memory results) = pf.getOracleTokenAverages(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].tick, 3737671);
        assertEq(results[0].liquidity, 500);

        // ~= 69
        assertEq(results[1].tick, -4234108);
        assertEq(results[1].liquidity, 7500);

        assertEq(results[2].tick, 0);
        assertEq(results[2].liquidity, type(uint128).max);

        assertEq(results[3].tick, 0);
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

        (ot, results) = pf.getOracleTokenAverages(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].tick, 3737671);
        // went up by not a lot
        assertEq(results[0].liquidity, 909);

        // ~= 69
        assertEq(results[1].tick, -4234108);
        // went down by half
        assertEq(results[1].liquidity, 3750);

        assertEq(results[2].tick, 0);
        assertEq(results[2].liquidity, type(uint128).max);

        // insufficient history
        assertEq(results[3].tick, 0);
        assertEq(results[3].liquidity, 0);

        // 148 o / n
        createOraclePool(NATIVE_TOKEN_ADDRESS, 5000000);
        updateOraclePoolLiquidity(NATIVE_TOKEN_ADDRESS, 500);

        (uint256 blockTimestamp, uint256 baseFee, uint256[] memory prices) =
            pf.getBlockInfoAndNativeTokenPrices(30, 0, baseTokens);
        assertEq(blockTimestamp, vm.getBlockTimestamp());
        assertEq(baseFee, block.basefee);
        assertEq(prices.length, 5);
        assertEq(prices[0], 0);
        assertEq(prices[1], 0);
        assertEq(prices[2], 0);
        assertEq(prices[3], 0);
        assertEq(prices[4], 0);

        advanceTime(30);

        (blockTimestamp, baseFee, prices) = pf.getBlockInfoAndNativeTokenPrices(30, 0, baseTokens);
        assertEq(prices.length, 5);
        assertEq(prices[0], 96297985063700310113393966209515390562);
        assertEq(prices[1], 33229155222854661650780398380107593);
        assertEq(prices[2], 2292810285051363400276741638672651164);
        assertEq(prices[3], 0);
        assertEq(prices[4], 229280977735010299375115010596996553350733);

        (blockTimestamp, baseFee, prices) = pf.getBlockInfoAndNativeTokenPrices(30, 100, baseTokens);
        vm.snapshotGasLastCall("pf.getBlockInfoAndNativeTokenPrices(30, 100, baseTokens[5])");
        assertEq(prices.length, 5);
        assertEq(prices[0], 96297985063700310113393966209515390562);
        assertEq(prices[1], 33229155222854661650780398380107593);
        assertEq(prices[2], 2292810285051363400276741638672651164);
        assertEq(prices[3], 0);
        assertEq(prices[4], 229280977735010299375115010596996553350733);
    }

    function test_getAverageMultihop() public {
        uint64 startTime = uint64(block.timestamp);
        // 2 o / token0
        PoolKey memory poolKey0 =
            createPool(address(oracleToken), address(token0), -693147, 0, MAX_TICK_SPACING, address(oracle));
        // 0.25 o / token1
        PoolKey memory poolKey1 =
            createPool(address(oracleToken), address(token1), 693147 * 2, 0, MAX_TICK_SPACING, address(oracle));

        createPosition(poolKey0, Bounds(MIN_TICK, MAX_TICK), 2000, 1000); // ~1414
        createPosition(poolKey1, Bounds(MIN_TICK, MAX_TICK), 3000, 12000); // ~6000

        advanceTime(12);

        // to 1 o / token0, meaning more token0 is sold into the pool
        movePrice(poolKey0, 0);
        // to 0.004 o / token1, meaning much more token1 is sold into the pool
        movePrice(poolKey1, 693147 * 8);

        advanceTime(12);

        // first 12 seconds the token1/token0 price is 1 token1 / 8 token0
        PriceFetcher.PeriodAverage memory average =
            pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 12);
        // combined should be about sqrt(1000*12000) = ~3464
        assertEq(average.liquidity, 3461);
        assertEq(average.tick, 2079441); // ~= 8

        // first half of first period is the same
        average = pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 6);
        assertEq(average.liquidity, 3461);
        assertEq(average.tick, 2079441);

        // liquidity goes up considerably because token0 and token1 are sold into the pools
        average = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 6, startTime + 18);
        assertEq(average.liquidity, 6352);
        assertEq(average.tick, 3812308); // ~= 45.254680164500577

        // second period
        average = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 12, startTime + 24);
        assertEq(average.liquidity, 11645);
        assertEq(average.tick, 5545176); // ~= 1.000001^(5545176) ~= 255.998920433432485

        // second half of second period
        average = pf.getAveragesOverPeriod(address(token0), address(token1), startTime + 18, startTime + 24);
        assertEq(average.liquidity, 11645);
        assertEq(average.tick, 5545176);

        pf.getAveragesOverPeriod(address(token0), address(token1), startTime, startTime + 24);
        vm.snapshotGasLastCall("getAveragesOverPeriod");

        PriceFetcher.PeriodAverage[] memory averages =
            pf.getHistoricalPeriodAverages(address(token0), address(token1), startTime + 24, 3, 5);
        vm.snapshotGasLastCall("getHistoricalPeriodAverages");
        assertEq(averages.length, 3);
        assertEq(averages[0].tick, 3465734);
        assertEq(averages[1].tick, 5545176);
        assertEq(averages[2].tick, 5545176);

        assertEq(averages[0].liquidity, 5625);
        assertEq(averages[1].liquidity, 11640);
        assertEq(averages[2].liquidity, 11645);

        assertEq(
            // high because the price did >10x
            pf.getRealizedVolatilityOverPeriod(address(token0), address(token1), startTime + 24, 3, 5, 15),
            2546785
        );
        vm.snapshotGasLastCall("getRealizedVolatilityOverPeriod");

        uint64 queryStartTime;
        (queryStartTime, averages) =
            pf.getAvailableHistoricalPeriodAverages(address(token0), address(token1), startTime + 24, 5, 5);
        assertEq(queryStartTime, startTime + 4);
        assertEq(averages.length, 4);
        assertEq(averages[0].tick, 2079441); // +9
        assertEq(averages[1].tick, 3465734); // +14
        assertEq(averages[2].tick, 5545176); // +19
        assertEq(averages[3].tick, 5545176); // +24

        assertEq(averages[0].liquidity, 3461);
        assertEq(averages[1].liquidity, 5625);
        assertEq(averages[2].liquidity, 11640);
        assertEq(averages[3].liquidity, 11645);
    }
}
