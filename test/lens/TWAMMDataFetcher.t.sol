// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "../Orders.t.sol";
import {PoolState, TWAMMDataFetcher, getAllValidTimes} from "../../src/lens/TWAMMDataFetcher.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {isTimeValid} from "../../src/math/time.sol";
import {OrderKey} from "../../src/extensions/TWAMM.sol";

contract TWAMMDataFetcherTest is BaseOrdersTest {
    TWAMMDataFetcher internal tdf;

    function setUp() public override {
        BaseOrdersTest.setUp();
        tdf = new TWAMMDataFetcher(core, twamm);
    }

    function test_getAllValidTimes(uint256 currentTime) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint64).max);

        uint256[] memory times = getAllValidTimes(currentTime);

        assertGt(times[0], currentTime);
        assertLe(times[0], currentTime + 16);

        for (uint256 i = 0; i < times.length; i++) {
            if (i != 0) {
                assertGt(times[i], times[i - 1], "ordered");
            }
            assertTrue(isTimeValid(currentTime, times[i]), "valid");
        }

        assertTrue(times.length == 105 || times.length == 106);
    }

    function test_getAllValidTimes_example() public pure {
        uint256[] memory times = getAllValidTimes(1);
        assertEq(times[0], 16);
        assertEq(times[1], 32);
        assertEq(times[14], 240);
        assertEq(times[15], 256);
        assertEq(times[16], 512);
        assertEq(times[29], 3840);
        assertEq(times[30], 4096);
        assertEq(times[31], 8192);
        assertEq(times[44], 61440);
        assertEq(times[45], 65536);
        assertEq(times[46], 131072);
        assertEq(times[times.length - 2], 4026531840);
        assertEq(times[times.length - 1], 4294967296);
    }

    function test_getPoolState_empty() public {
        PoolKey memory poolKey = createTwammPool(1000, 693147);
        PoolState memory result = tdf.getPoolState(poolKey);
        assertEq(result.tick, 693147);
        assertEq(result.sqrtRatio.toFixed(), 481231811499356508032916671135276335104);
        assertEq(result.liquidity, 0);
        assertEq(result.lastVirtualOrderExecutionTime, 1);
        assertEq(result.saleRateToken0, 0);
        assertEq(result.saleRateToken1, 0);
        assertEq(result.saleRateDeltas.length, 0);
    }

    function test_getPoolState_pool_with_orders_no_time_advance() public {
        PoolKey memory poolKey = createTwammPool(1000, 693147);
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);
        orders.mintAndIncreaseSellAmount(
            OrderKey({sellToken: address(token0), buyToken: address(token1), fee: 1000, startTime: 0, endTime: 16}),
            10000,
            type(uint112).max
        );

        orders.mintAndIncreaseSellAmount(
            OrderKey({sellToken: address(token1), buyToken: address(token0), fee: 1000, startTime: 32, endTime: 256}),
            25000,
            type(uint112).max
        );

        PoolState memory result = tdf.getPoolState(poolKey);
        assertEq(result.tick, 693147);
        assertEq(result.sqrtRatio.toFixed(), 481231811499356508032916671135276335104);
        assertEq(result.liquidity, 0);
        assertEq(result.lastVirtualOrderExecutionTime, 1);
        assertEq(result.saleRateToken0, (uint112(10000) << 32) / 15);
        assertEq(result.saleRateToken1, 0);
        assertEq(result.saleRateDeltas.length, 3);
        assertEq(result.saleRateDeltas[0].time, 16);
        assertEq(result.saleRateDeltas[0].saleRateDelta0, -int112((uint112(10000) << 32) / 15));
        assertEq(result.saleRateDeltas[0].saleRateDelta1, 0);
        assertEq(result.saleRateDeltas[1].time, 32);
        assertEq(result.saleRateDeltas[1].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[1].saleRateDelta1, int112((uint112(25000) << 32) / 224));
        assertEq(result.saleRateDeltas[2].time, 256);
        assertEq(result.saleRateDeltas[2].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[2].saleRateDelta1, -((int112(25000) << 32) / 224));

        advanceTime(15);
        PoolState memory resultNext = tdf.getPoolState(poolKey);
        assertEq(result.tick, resultNext.tick);
        assertEq(result.sqrtRatio.toFixed(), resultNext.sqrtRatio.toFixed());
        assertEq(result.liquidity, resultNext.liquidity);
        assertEq(result.lastVirtualOrderExecutionTime, resultNext.lastVirtualOrderExecutionTime);
        assertEq(result.saleRateToken0, resultNext.saleRateToken0);
        assertEq(result.saleRateToken1, resultNext.saleRateToken1);
        assertEq(result.saleRateDeltas.length, resultNext.saleRateDeltas.length);

        result = tdf.executeVirtualOrdersAndGetPoolState(poolKey);
        assertEq(result.tick, -88722836);
        assertEq(result.sqrtRatio.toFixed(), 18447191164202170524);
        assertEq(result.liquidity, 0);
        assertEq(result.lastVirtualOrderExecutionTime, 16);
        assertEq(result.saleRateToken0, 0);
        assertEq(result.saleRateToken1, 0);
        assertEq(result.saleRateDeltas.length, 2);
        assertEq(result.saleRateDeltas[0].time, 32);
        assertEq(result.saleRateDeltas[0].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[0].saleRateDelta1, int112((uint112(25000) << 32) / 224));
        assertEq(result.saleRateDeltas[1].time, 256);
        assertEq(result.saleRateDeltas[1].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[1].saleRateDelta1, -((int112(25000) << 32) / 224));
    }
}
