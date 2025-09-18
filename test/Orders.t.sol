// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {PositionId} from "../src/types/positionId.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {nextValidTime} from "../src/math/time.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TWAMMLib} from "../src/libraries/TWAMMLib.sol";
import {Orders} from "../src/Orders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {TWAMM} from "../src/extensions/TWAMM.sol";
import {ITWAMM, OrderKey} from "../src/interfaces/extensions/ITWAMM.sol";

abstract contract BaseOrdersTest is BaseTWAMMTest {
    Orders internal orders;

    function setUp() public virtual override {
        BaseTWAMMTest.setUp();

        orders = new Orders(core, twamm, owner);
    }
}

contract OrdersTest is BaseOrdersTest {
    using CoreLib for *;
    using TWAMMLib for *;

    function test_createOrder_sell_token0_only(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

    function test_executeVirtualOrdersAndGetCurrentOrderInfo_after_stop_future_order_partway(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time + 15,
            endTime: time + 31
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        advanceTime(23);

        orders.collectProceeds(id, key, address(this));
        orders.decreaseSaleRate(id, key, saleRate, address(this));

        advanceTime(4);

        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertEq(saleRateAfter, 0);
        assertEq(remainingSellAmount, 0);
        assertEq(purchasedAmount, 0);
        assertEq(amountSold, 500000000000000000);
    }

    function test_executeVirtualOrder_fails_in_max_times() public {
        uint256 time = type(uint256).max - type(uint32).max - 15;
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time + 15,
            endTime: time + 31
        });

        orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        advanceTime(23);
        twamm.lockAndExecuteVirtualOrders(poolKey);

        advanceTime(9);
        // nextValidTime will return 0 which causes it to skip the initialized time and try to swap too much
        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        twamm.lockAndExecuteVirtualOrders(poolKey);
    }

    function test_executeVirtualOrdersAndGetCurrentOrderInfo_after_future_order_ends(uint256 time) public {
        // we use 33 because we advance time by 32 during the test
        time = boundTime(time, 33);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            sellToken: poolKey.token0,
            buyToken: poolKey.token1,
            fee: fee,
            startTime: time + 15,
            endTime: time + 31
        });
        (uint256 id,) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        advanceTime(23);

        assertEq(orders.collectProceeds(id, key, address(this)), 0.322033898305084744e18);

        advanceTime(8);

        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertEq(saleRateAfter, (1e18 << 32) / 16);
        assertEq(remainingSellAmount, 0);
        assertEq(purchasedAmount, 0.165145588874402432e18);
        assertEq(amountSold, 1e18);

        advanceTime(1);

        // does not change after advancing past the last time
        (saleRateAfter, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertEq(saleRateAfter, (1e18 << 32) / 16);
        assertEq(remainingSellAmount, 0);
        assertEq(purchasedAmount, 0.165145588874402432e18);
        assertEq(amountSold, 1e18);
    }

    function test_createOrder_sell_both_tokens_getOrderInfo(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

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
            endTime: time + 63
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2e18, type(uint112).max);

        advanceTime(15);

        (uint256 saleRate0, uint256 amountSold0, uint256 remainingSellAmount0, uint256 purchasedAmount0) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id0, key0);
        assertEq(saleRate0, (uint112(1e18) << 32) / 15, "saleRate0");
        assertEq(amountSold0, 1e18 - 1, "amountSold0");
        assertEq(remainingSellAmount0, 0, "remainingSellAmount0");
        assertEq(purchasedAmount0, 0.714364266211129184e18, "purchasedAmount0");
        (uint256 saleRate1, uint256 amountSold1, uint256 remainingSellAmount1, uint256 purchasedAmount1) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id1, key1);
        assertEq(saleRate1, (uint112(2e18) << 32) / 63, "saleRate1");
        assertEq(amountSold1, 0.47619047619047619e18, "amountSold1");
        assertEq(remainingSellAmount1, 1.52380952380952381e18, "remainingSellAmount1");
        assertEq(purchasedAmount1, 0.670910176928520699e18, "purchasedAmount1");

        // advanced to the last time that this function should work (2**32 + start time - 1)
        advanceTime(type(uint32).max - 16);

        (saleRate0, amountSold0, remainingSellAmount0, purchasedAmount0) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id0, key0);
        assertEq(saleRate0, (uint112(1e18) << 32) / 15, "saleRate0");
        assertEq(amountSold0, 1e18 - 1, "amountSold0");
        assertEq(remainingSellAmount0, 0, "remainingSellAmount0");
        assertEq(purchasedAmount0, 0.714364266211129184e18, "purchasedAmount0");

        (saleRate1, amountSold1, remainingSellAmount1, purchasedAmount1) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id1, key1);
        assertEq(saleRate1, (uint112(2e18) << 32) / 63, "saleRate1");
        assertEq(amountSold1, 2e18 - 1, "amountSold1");
        assertEq(remainingSellAmount1, 0, "remainingSellAmount1");
        assertEq(purchasedAmount1, 1.530943211251159013e18, "purchasedAmount1");
    }

    function test_createOrder_sell_both_tokens_liquidity_dominated(uint256 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

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

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

        assertEq(orders.decreaseSaleRate(id, key, saleRate / 2, address(this)), 21);
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

        vm.expectRevert(ITWAMM.PoolNotInitialized.selector);
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
    }

    function test_collectProceeds_non_existent_pool(uint256 time) public {
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: address(token0), buyToken: address(token1), fee: fee, startTime: 0, endTime: 1});

        uint256 id = orders.mint();

        vm.expectRevert(ITWAMM.PoolNotInitialized.selector);
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

        (uint128 liquidity0,,) = positions.deposit(
            pID, poolKey, MIN_TICK, MAX_TICK, 9065869775701580912051, 16591196256327018126941976177968210, 0
        );

        advanceTime(102_399);

        (uint128 liquidity1,,) =
            positions.deposit(pID, poolKey, MIN_TICK, MAX_TICK, 229636410600502050710229286961, 502804080817310396, 0);
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

        (uint128 liquidity2,,) = positions.deposit(
            pID, poolKey, MIN_TICK, MAX_TICK, 1412971749302168760052394, 35831434466998775335139276644539, 0
        );

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
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        coolAllContracts();
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(first order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders single sided");
    }

    function test_gas_costs_double_sided() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 =
            OrderKey({sellToken: poolKey.token0, buyToken: poolKey.token1, fee: fee, startTime: 0, endTime: 16});
        orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 =
            OrderKey({sellToken: poolKey.token1, buyToken: poolKey.token0, fee: fee, startTime: 0, endTime: 16});
        coolAllContracts();
        orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(second order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders double sided");
    }

    function test_gas_costs_double_sided_order_crossed() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

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

    function test_lockAndExecuteVirtualOrders_maximum_gas_cost() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        uint256 time = block.timestamp;
        uint256 i = 0;

        while (true) {
            uint256 startTime = nextValidTime(block.timestamp, time);
            uint256 endTime = nextValidTime(block.timestamp, startTime);

            if (startTime == 0 || endTime == 0) break;

            orders.mintAndIncreaseSellAmount(
                OrderKey({
                    sellToken: poolKey.token0,
                    buyToken: poolKey.token1,
                    fee: fee,
                    startTime: startTime,
                    endTime: endTime
                }),
                uint112(100 * (i++)),
                type(uint112).max
            );

            orders.mintAndIncreaseSellAmount(
                OrderKey({
                    sellToken: poolKey.token1,
                    buyToken: poolKey.token0,
                    fee: fee,
                    startTime: startTime,
                    endTime: endTime
                }),
                uint112(100 * (i++)),
                type(uint112).max
            );

            time = startTime;
        }

        advanceTime(type(uint32).max);

        coolAllContracts();
        twamm.lockAndExecuteVirtualOrders(poolKey);
        vm.snapshotGasLastCall("lockAndExecuteVirtualOrders max cost");
    }
}
