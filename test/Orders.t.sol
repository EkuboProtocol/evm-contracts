// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../src/libraries/TWAMMLib.sol";
import {FeeAccumulatingExtension} from "./SolvencyInvariantTest.t.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {Orders} from "../src/Orders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {TWAMM, OrderKey} from "../src/extensions/TWAMM.sol";

abstract contract BaseOrdersTest is BaseTWAMMTest {
    Orders internal orders;
    BaseURLTokenURIGenerator internal tokenUriGenerator;

    function setUp() public virtual override {
        BaseTWAMMTest.setUp();

        tokenUriGenerator = new BaseURLTokenURIGenerator(address(this), "orders://");
        orders = new Orders(core, twamm, tokenUriGenerator);
    }
}

contract OrdersTest is BaseOrdersTest {
    using CoreLib for *;
    using TWAMMLib for *;

    function boundTime(uint256 time, uint32 offset) internal pure returns (uint256) {
        return ((bound(time, offset, type(uint256).max - type(uint32).max) / 16) * 16) + offset;
    }

    function test_createOrder_sell_token0_only(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        assertEq(saleRate, (uint256(100) << 32) / 15);

        advanceTime(15);

        assertEq(orders.collectProceeds(id, key, address(this)), 92);
    }

    function test_createOrder_sell_token1_only(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token1,
            buyToken: poolKey.token0,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        assertEq(saleRate, (uint256(100) << 32) / 15);

        advanceTime(15);

        assertEq(orders.collectProceeds(id, key, address(this)), 92);
    }

    function test_createOrder_sell_both_tokens(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 = OrderKey({
            sellToken: poolKey.token1,
            buyToken: poolKey.token0,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);

        advanceTime(15);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 98);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 98);
    }

    function test_createOrder_sell_both_tokens_sale_rate_dominated(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 1e18, type(uint112).max);
        OrderKey memory key1 = OrderKey({
            sellToken: poolKey.token1,
            buyToken: poolKey.token0,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2e18, type(uint112).max);

        advanceTime(15);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 1999999999999995636);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 1000000000000002926);
    }

    function test_createOrder_sell_both_tokens_liquidity_dominated(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 1000, type(uint112).max);
        OrderKey memory key1 = OrderKey({
            sellToken: poolKey.token1,
            buyToken: poolKey.token0,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2000, type(uint112).max);

        advanceTime(15);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 998);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 1947);
    }

    function test_createOrder_stop_order(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);

        advanceTime(8);

        assertEq(orders.decreaseSaleRate(id, key, saleRate / 2, 21, address(this)), 21);
        assertEq(orders.collectProceeds(id, key, address(this)), 47);

        advanceTime(8);
        assertEq(orders.collectProceeds(id, key, address(this)), 18);
    }

    function test_createOrder_non_existent_pool(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: address(token0),
            buyToken: address(token1),
            fee: fee,
            startTime: time - 1,
            endTime: time + 15
        });

        vm.expectRevert(TWAMM.PoolNotInitialized.selector);
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
    }

    function test_collectProceeds_non_existent_pool(uint256 time) public {
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: address(token0), buyToken: address(token1), fee: fee, startTime: 0, endTime: 1});

        uint256 id = orders.mint();

        vm.expectRevert(TWAMM.PoolNotInitialized.selector);
        orders.collectProceeds(id, key, address(this));
    }

    function test_invariant_test_failure_delta_overflows_int128_unchecked() public {
        vm.warp(4294901760);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: toConfig({_extension: address(twamm), _fee: 6969, _tickSpacing: 0})
        });
        bytes32 poolId = poolKey.toPoolId();
        positions.maybeInitializePool(poolKey, -18135370); // 0.000000013301874 token1/token0

        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(poolId);

        assertEq(sqrtRatio.toFixed(), 39246041149524737549342346187898880);
        assertEq(tick, -18135370);
        assertEq(liquidity, 0);

        uint256 oID = orders.mint();
        uint112 saleRateOrder0 = orders.increaseSellAmount(
            oID,
            OrderKey({
                sellToken: poolKey.token1,
                buyToken: poolKey.token0,
                fee: poolKey.fee(),
                startTime: 4294902272,
                endTime: 4311744512
            }),
            6849779285538874832820657709,
            type(uint112).max
        );

        (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1) = twamm.poolState(poolId);
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        // 0 because the order starts in the future
        assertEq(saleRateToken0, 0);
        assertEq(saleRateToken1, 0);

        uint256 pID = positions.mint();
        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);

        (uint128 liquidity0,,) =
            positions.deposit(pID, poolKey, bounds, 9065869775701580912051, 16591196256327018126941976177968210, 0);

        advanceTime(102_399);

        (uint128 liquidity1,,) =
            positions.deposit(pID, poolKey, bounds, 229636410600502050710229286961, 502804080817310396, 0);
        (sqrtRatio, tick, liquidity) = core.poolState(poolId);

        assertEq(sqrtRatio.toFixed(), 13485562298671080879303606629460147559991345152);
        assertEq(tick, 34990236); // ~=1570575495728187 token1/token0
        assertEq(liquidity, liquidity0 + liquidity1);

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId);
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, 0);
        assertEq(saleRateToken1, saleRateOrder0);

        uint112 saleRateOrder1 = orders.increaseSellAmount(
            oID,
            OrderKey({
                sellToken: poolKey.token0,
                buyToken: poolKey.token1,
                fee: poolKey.fee(),
                startTime: 4295004176,
                endTime: 4295294976
            }),
            28877500254,
            type(uint112).max
        );

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId);
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, 0);
        assertEq(saleRateToken1, saleRateOrder0);

        router.swap(poolKey, false, 170141183460469231731563853878917070850, MIN_SQRT_RATIO, 145);

        (sqrtRatio, tick, liquidity) = core.poolState(poolId);

        assertEq(sqrtRatio.toFixed(), 8721205675552749603540);
        assertEq(tick, -76405628); // ~=-2.2454E-31 token1/token0
        assertEq(liquidity, liquidity0 + liquidity1);

        (uint128 liquidity2,,) =
            positions.deposit(pID, poolKey, bounds, 1412971749302168760052394, 35831434466998775335139276644539, 0);

        (,, liquidity) = core.poolState(poolId);
        assertEq(liquidity, liquidity0 + liquidity1 + liquidity2);

        advanceTime(164154);

        twamm.lockAndExecuteVirtualOrders(poolKey);

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId);
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, saleRateOrder1);
        assertEq(saleRateToken1, saleRateOrder0);
    }

    function test_gas_costs_single_sided() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(first order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders single sided");
    }

    function test_gas_costs_double_sided() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 =
            OrderKey({sellToken: poolKey.token1, buyToken: poolKey.token0, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(second order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders double sided");
    }

    function test_gas_costs_double_sided_order_crossed() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 =
            OrderKey({sellToken: poolKey.token1, buyToken: poolKey.token0, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);

        advanceTime(15);

        token0.approve(address(router), type(uint256).max);
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders double sided crossed");
    }
}
