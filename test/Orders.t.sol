// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FeeAccumulatingExtension} from "./SolvencyInvariantTest.t.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {Orders} from "../src/Orders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {OrderKey} from "../src/extensions/TWAMM.sol";

contract OrdersTest is BaseTWAMMTest {
    Orders internal orders;
    BaseURLTokenURIGenerator internal tokenUriGenerator;

    function setUp() public override {
        BaseTWAMMTest.setUp();

        tokenUriGenerator = new BaseURLTokenURIGenerator(address(this), "orders://");
        orders = new Orders(core, twamm, tokenUriGenerator);
    }

    function test_createOrder_sell_token0_only() public {
        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        vm.warp(1);

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        assertEq(saleRate, (uint256(100) << 32) / 15);

        advanceTime(15);

        assertEq(orders.collectProceeds(id, key, address(this)), 92);
    }

    function test_createOrder_sell_token1_only() public {
        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        vm.warp(1);

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: poolKey.token1, buyToken: poolKey.token0, fee: fee, startTime: 0, endTime: 16});
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        assertEq(saleRate, (uint256(100) << 32) / 15);

        advanceTime(15);

        assertEq(orders.collectProceeds(id, key, address(this)), 92);
    }

    function test_createOrder_sell_both_tokens() public {
        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        vm.warp(1);

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 =
            OrderKey({sellToken: poolKey.token1, buyToken: poolKey.token0, fee: fee, startTime: 0, endTime: 16});
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);

        advanceTime(15);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 98);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 98);
    }

    function test_createOrder_stop_order() public {
        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        vm.warp(1);

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);

        advanceTime(8);

        assertEq(orders.decreaseSaleRate(id, key, saleRate / 2, 20, address(this)), 20);
        assertEq(orders.collectProceeds(id, key, address(this)), 47);

        advanceTime(8);
        assertEq(orders.collectProceeds(id, key, address(this)), 18);
    }
}
