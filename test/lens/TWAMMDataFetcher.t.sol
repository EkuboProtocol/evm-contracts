// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "../Orders.t.sol";
import {PoolState, TWAMMDataFetcher, getAllValidFutureTimes} from "../../src/lens/TWAMMDataFetcher.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {isTimeValid, nextValidTime} from "../../src/math/time.sol";
import {OrderKey} from "../../src/extensions/TWAMM.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract TWAMMDataFetcherTest is BaseOrdersTest {
    TWAMMDataFetcher internal tdf;

    function setUp() public override {
        BaseOrdersTest.setUp();
        tdf = new TWAMMDataFetcher(core, twamm);
    }

    function test_getAllValidFutureTimes_invariants(uint256 currentTime) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint32).max);
        uint256[] memory times = getAllValidFutureTimes(currentTime);

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

    function test_getAllValidFutureTimes_example() public pure {
        uint256[] memory times = getAllValidFutureTimes(1);
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

    function test_getPoolState_returns_all_valid_times(uint64 fee, int32 startingTick, uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        startingTick = int32(bound(startingTick, MIN_TICK, MAX_TICK));

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: startingTick});
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        uint256 ordersPlaced = 0;
        uint256 startTime = nextValidTime(time, time);
        uint256 lastTime;
        while (true) {
            uint256 endTime = nextValidTime(time, startTime);
            if (endTime == 0) break;
            lastTime = FixedPointMathLib.max(endTime, lastTime);

            orders.mintAndIncreaseSellAmount(
                ordersPlaced % 2 == 0
                    ? OrderKey({
                        sellToken: address(token0),
                        buyToken: address(token1),
                        fee: fee,
                        startTime: startTime,
                        endTime: endTime
                    })
                    : OrderKey({
                        sellToken: address(token1),
                        buyToken: address(token0),
                        fee: fee,
                        startTime: startTime,
                        endTime: endTime
                    }),
                10000,
                type(uint112).max
            );

            ordersPlaced++;

            startTime = nextValidTime(time, endTime);
            if (startTime == 0) break;

            lastTime = FixedPointMathLib.max(startTime, lastTime);
        }

        PoolState memory result = tdf.getPoolState(poolKey);
        assertEq(result.saleRateDeltas.length, 106);
        assertEq(result.liquidity, 0);
        assertEq(result.saleRateDeltas[105].time, lastTime);

        for (uint256 i = 1; i < result.saleRateDeltas.length; i += 2) {
            int256 delta;
            int256 deltaPrev;
            if ((i / 2) % 2 == 0) {
                assertEq(result.saleRateDeltas[i].saleRateDelta1, 0);
                assertNotEq(result.saleRateDeltas[i].saleRateDelta0, 0);

                delta = result.saleRateDeltas[i].saleRateDelta0;
                deltaPrev = result.saleRateDeltas[i - 1].saleRateDelta0;
            } else {
                assertEq(result.saleRateDeltas[i].saleRateDelta0, 0);
                assertNotEq(result.saleRateDeltas[i].saleRateDelta1, 0);

                delta = result.saleRateDeltas[i].saleRateDelta1;
                deltaPrev = result.saleRateDeltas[i - 1].saleRateDelta1;
            }

            assertEq(-delta, deltaPrev, "delta cancels out");
        }
    }

    function test_getPoolState_pool_with_orders_no_time_advance(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        PoolKey memory poolKey = createTwammPool(1000, 693147);
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);
        orders.mintAndIncreaseSellAmount(
            OrderKey({
                sellToken: address(token0),
                buyToken: address(token1),
                fee: 1000,
                startTime: 0,
                endTime: time + 15
            }),
            10000,
            type(uint112).max
        );

        orders.mintAndIncreaseSellAmount(
            OrderKey({
                sellToken: address(token1),
                buyToken: address(token0),
                fee: 1000,
                startTime: time + 31,
                endTime: time + 255
            }),
            25000,
            type(uint112).max
        );

        PoolState memory result = tdf.getPoolState(poolKey);
        assertEq(result.tick, 693147);
        assertEq(result.sqrtRatio.toFixed(), 481231811499356508032916671135276335104);
        assertEq(result.liquidity, 0);
        assertEq(result.lastVirtualOrderExecutionTime, time);
        assertEq(result.saleRateToken0, (uint112(10000) << 32) / 15);
        assertEq(result.saleRateToken1, 0);
        assertEq(result.saleRateDeltas.length, 3);
        assertEq(result.saleRateDeltas[0].time, time + 15);
        assertEq(result.saleRateDeltas[0].saleRateDelta0, -int112((uint112(10000) << 32) / 15));
        assertEq(result.saleRateDeltas[0].saleRateDelta1, 0);
        assertEq(result.saleRateDeltas[1].time, time + 31);
        assertEq(result.saleRateDeltas[1].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[1].saleRateDelta1, int112((uint112(25000) << 32) / 224));
        assertEq(result.saleRateDeltas[2].time, time + 255);
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
        assertEq(result.lastVirtualOrderExecutionTime, time + 15);
        assertEq(result.saleRateToken0, 0);
        assertEq(result.saleRateToken1, 0);
        assertEq(result.saleRateDeltas.length, 2);
        assertEq(result.saleRateDeltas[0].time, time + 31);
        assertEq(result.saleRateDeltas[0].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[0].saleRateDelta1, int112((uint112(25000) << 32) / 224));
        assertEq(result.saleRateDeltas[1].time, time + 255);
        assertEq(result.saleRateDeltas[1].saleRateDelta0, 0);
        assertEq(result.saleRateDeltas[1].saleRateDelta1, -((int112(25000) << 32) / 224));
    }
}
