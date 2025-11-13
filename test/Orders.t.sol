// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {PoolKey} from "../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {nextValidTime} from "../src/math/time.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../src/libraries/TWAMMLib.sol";
import {Orders} from "../src/Orders.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {ITWAMM, OrderKey} from "../src/interfaces/extensions/ITWAMM.sol";
import {TwammPoolState} from "../src/types/twammPoolState.sol";
import {createOrderConfig} from "../src/types/orderConfig.sol";

abstract contract BaseOrdersTest is BaseTWAMMTest {
    uint32 internal constant MIN_TWAMM_DURATION = 256;
    uint32 internal constant HALF_MIN_TWAMM_DURATION = MIN_TWAMM_DURATION / 2;

    Orders internal orders;

    function setUp() public virtual override {
        BaseTWAMMTest.setUp();

        orders = new Orders(core, twamm, owner);
    }

    function alignToNextValidTime() internal returns (uint64 startTime) {
        uint64 current = uint64(vm.getBlockTimestamp());
        startTime = uint64(nextValidTime(current, current));
        vm.warp(startTime);
    }
}

contract OrdersTest is BaseOrdersTest {
    using CoreLib for *;
    using TWAMMLib for *;

    function test_createOrder_sell_token0_only(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime));

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);
        uint112 expectedSaleRate = uint112((uint256(100) << 32) / (endTime - startTime));
        assertEq(saleRate, expectedSaleRate);

        advanceTime(endTime - startTime);

        assertEq(orders.collectProceeds(id, key, address(this)), 93);
    }

    function test_createOrder_sell_token1_only(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token1.approve(address(orders), type(uint256).max);

        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime));

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);
        uint112 expectedSaleRate = uint112((uint256(100) << 32) / (endTime - startTime));
        assertEq(saleRate, expectedSaleRate);

        advanceTime(endTime - startTime);

        assertEq(orders.collectProceeds(id, key, address(this)), 93);
    }

    function test_createOrder_sell_both_tokens(uint64 time) public {
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
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);

        advanceTime(255);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 98);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 98);
    }

    function test_createOrder_sell_both_tokens_sale_rate_dominated(uint64 time) public {
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
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 1e18, type(uint112).max);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2e18, type(uint112).max);

        advanceTime(255);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 1999999999999995636);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 1000000000000002926);
    }

    function test_executeVirtualOrdersAndGetCurrentOrderInfo_after_stop_future_order_partway(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time + 255, _endTime: time + 511})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        advanceTime(383);

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

    function test_executeVirtualOrdersAndGetCurrentOrderInfo_after_future_order_ends(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time + 255, _endTime: time + 511})
        });
        (uint256 id,) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        advanceTime(383);

        assertEq(orders.collectProceeds(id, key, address(this)), 0.322033898305084744e18);

        advanceTime(128);

        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertEq(saleRateAfter, (1e18 << 32) / 256);
        assertEq(remainingSellAmount, 0);
        assertEq(purchasedAmount, 0.165145588874402432e18);
        assertEq(amountSold, 1e18);

        advanceTime(1);

        // does not change after advancing past the last time
        (saleRateAfter, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertEq(saleRateAfter, (1e18 << 32) / 256);
        assertEq(remainingSellAmount, 0);
        assertEq(purchasedAmount, 0.165145588874402432e18);
        assertEq(amountSold, 1e18);
    }

    function test_createOrder_sell_both_tokens_getOrderInfo(uint64 time) public {
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
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 1e18, type(uint112).max);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 767})
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2e18, type(uint112).max);

        advanceTime(255);

        (uint256 saleRate0, uint256 amountSold0, uint256 remainingSellAmount0, uint256 purchasedAmount0) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id0, key0);
        assertEq(saleRate0, (uint112(1e18) << 32) / 255, "saleRate0");
        assertEq(amountSold0, 1e18 - 1, "amountSold0");
        assertEq(remainingSellAmount0, 0, "remainingSellAmount0");
        assertEq(purchasedAmount0, 0.714364266211129184e18, "purchasedAmount0");
        (uint256 saleRate1, uint256 amountSold1, uint256 remainingSellAmount1, uint256 purchasedAmount1) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id1, key1);
        assertEq(saleRate1, (uint112(2e18) << 32) / 767, "saleRate1");
        assertEq(amountSold1, 0.47619047619047619e18, "amountSold1");
        assertEq(remainingSellAmount1, 1.52380952380952381e18, "remainingSellAmount1");
        assertEq(purchasedAmount1, 0.670910176928520699e18, "purchasedAmount1");

        // advanced to the last time that this function should work (2**32 + start time - 1)
        advanceTime(type(uint32).max - 256);

        (saleRate0, amountSold0, remainingSellAmount0, purchasedAmount0) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id0, key0);
        assertEq(saleRate0, (uint112(1e18) << 32) / 255, "saleRate0");
        assertEq(amountSold0, 1e18 - 1, "amountSold0");
        assertEq(remainingSellAmount0, 0, "remainingSellAmount0");
        assertEq(purchasedAmount0, 0.714364266211129184e18, "purchasedAmount0");

        (saleRate1, amountSold1, remainingSellAmount1, purchasedAmount1) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id1, key1);
        assertEq(saleRate1, (uint112(2e18) << 32) / 767, "saleRate1");
        assertEq(amountSold1, 2e18 - 1, "amountSold1");
        assertEq(remainingSellAmount1, 0, "remainingSellAmount1");
        assertEq(purchasedAmount1, 1.530943211251159013e18, "purchasedAmount1");
    }

    function test_createOrder_sell_both_tokens_liquidity_dominated(uint64 time) public {
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
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id0,) = orders.mintAndIncreaseSellAmount(key0, 1000, type(uint112).max);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id1,) = orders.mintAndIncreaseSellAmount(key1, 2000, type(uint112).max);

        advanceTime(255);

        // both get a better price!
        assertEq(orders.collectProceeds(id0, key0, address(this)), 998);
        assertEq(orders.collectProceeds(id1, key1, address(this)), 1947);
    }

    function test_createOrder_stop_order(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        // 5% fee pool
        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});

        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, 28633115306);

        advanceTime(128);

        assertEq(orders.decreaseSaleRate(id, key, saleRate / 2, address(this)), 23);
        assertEq(orders.collectProceeds(id, key, address(this)), 44);

        advanceTime(128);
        assertEq(orders.collectProceeds(id, key, address(this)), 19);
    }

    function test_createOrder_non_existent_pool(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: address(token0),
            token1: address(token1),
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 255})
        });

        vm.expectRevert(ITWAMM.PoolNotInitialized.selector);
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
    }

    function test_createOrder_uint32_bounds_does_not_revert(uint64 time) public {
        // we make time a multiple of 2**32
        // the pool state should be exactly 0
        time = (time >> 32) << 32;
        vm.warp(time);

        OrderKey memory key = OrderKey({
            token0: address(token0),
            token1: address(token1),
            config: createOrderConfig({_fee: 0, _isToken1: false, _startTime: 0, _endTime: time + 256})
        });
        positions.maybeInitializePool(key.toPoolKey(address(twamm)), 0);

        // pool state is legitimately 0 because it was initialized on a time that is a multiple of 2**32
        assertEq(TwammPoolState.unwrap(twamm.poolState(key.toPoolKey(address(twamm)).toPoolId())), bytes32(0));

        token0.approve(address(orders), type(uint256).max);
        orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);
    }

    function test_collectProceeds_non_existent_pool(uint64 time) public {
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: address(token0),
            token1: address(token1),
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 1})
        });

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
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: 6969})
        });
        PoolId poolId = poolKey.toPoolId();
        positions.maybeInitializePool(poolKey, -18135370); // 0.000000013301874 token1/token0

        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(poolId).parse();

        assertEq(sqrtRatio.toFixed(), 39246041149524737549342346187898880);
        assertEq(tick, -18135370);
        assertEq(liquidity, 0);

        uint256 oID = orders.mint();
        uint112 saleRateOrder0 = orders.increaseSellAmount(
            oID,
            OrderKey({
                token0: poolKey.token0,
                token1: poolKey.token1,
                config: createOrderConfig({
                    _fee: poolKey.config.fee(), _isToken1: true, _startTime: 4294902272, _endTime: 4311744512
                })
            }),
            6849779285538874832820657709,
            type(uint112).max
        );

        (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1) =
            twamm.poolState(poolId).parse();
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
        (sqrtRatio, tick, liquidity) = core.poolState(poolId).parse();

        assertEq(sqrtRatio.toFixed(), 13485562298671080879303606629460147559991345152);
        assertEq(tick, 34990236); // ~=1570575495728187 token1/token0
        assertEq(liquidity, liquidity0 + liquidity1);

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId).parse();
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, 0);
        assertEq(saleRateToken1, saleRateOrder0);

        uint112 saleRateOrder1 = orders.increaseSellAmount(
            oID,
            OrderKey({
                token0: poolKey.token0,
                token1: poolKey.token1,
                config: createOrderConfig({
                    _fee: poolKey.config.fee(), _isToken1: false, _startTime: 4295004176, _endTime: 4295294976
                })
            }),
            28877500254,
            type(uint112).max
        );

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId).parse();
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, 0);
        assertEq(saleRateToken1, saleRateOrder0);

        router.swap(poolKey, false, 170141183460469231731563853878917070850, MIN_SQRT_RATIO, 145);

        (sqrtRatio, tick, liquidity) = core.poolState(poolId).parse();

        assertEq(sqrtRatio.toFixed(), 8721205675552749603540);
        assertEq(tick, -76405628); // ~=-2.2454E-31 token1/token0
        assertEq(liquidity, liquidity0 + liquidity1);

        (uint128 liquidity2,,) = positions.deposit(
            pID, poolKey, MIN_TICK, MAX_TICK, 1412971749302168760052394, 35831434466998775335139276644539, 0
        );

        liquidity = core.poolState(poolId).liquidity();
        assertEq(liquidity, liquidity0 + liquidity1 + liquidity2);

        advanceTime(164154);

        twamm.lockAndExecuteVirtualOrders(poolKey);

        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolId).parse();
        assertEq(lastVirtualOrderExecutionTime, uint32(vm.getBlockTimestamp()));
        assertEq(saleRateToken0, saleRateOrder1);
        assertEq(saleRateToken1, saleRateOrder0);
    }

    /// forge-config: default.isolate = true
    function test_gas_costs_no_orders() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        advanceTime(15);

        token0.approve(address(router), type(uint256).max);
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders no orders");
    }

    /// forge-config: default.isolate = true
    function test_gas_costs_single_sided() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        coolAllContracts();
        orders.mintAndIncreaseSellAmount(key, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(first order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders single sided");
    }

    /// forge-config: default.isolate = true
    function test_gas_costs_double_sided() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: 0, _endTime: 256})
        });
        coolAllContracts();
        orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);
        vm.snapshotGasLastCall("mintAndIncreaseSellAmount(second order)");

        advanceTime(8);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders double sided");
    }

    /// forge-config: default.isolate = true
    function test_gas_costs_double_sided_order_crossed() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);

        OrderKey memory key0 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        orders.mintAndIncreaseSellAmount(key0, 100, 28633115306);
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: 0, _endTime: 256})
        });
        orders.mintAndIncreaseSellAmount(key1, 100, 28633115306);

        advanceTime(255);

        token0.approve(address(router), type(uint256).max);
        router.swap(poolKey, false, 100, MIN_SQRT_RATIO, 0, type(int256).min, address(this));
        vm.snapshotGasLastCall("swap and executeVirtualOrders double sided crossed");
    }

    /// forge-config: default.isolate = true
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
                    token0: poolKey.token0,
                    token1: poolKey.token1,
                    config: createOrderConfig({
                        _fee: fee, _isToken1: false, _startTime: uint64(startTime), _endTime: uint64(endTime)
                    })
                }),
                uint112(100 * (i++)),
                type(uint112).max
            );

            orders.mintAndIncreaseSellAmount(
                OrderKey({
                    token0: poolKey.token0,
                    token1: poolKey.token1,
                    config: createOrderConfig({
                        _fee: fee, _isToken1: true, _startTime: uint64(startTime), _endTime: uint64(endTime)
                    })
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

    // Tests for amountSold computation when orders are updated before they start
    function test_amountSold_update_before_start_then_query_before_start(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts in the future
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 512));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 256));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Query immediately after creation (before start)
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, saleRate, "sale rate should match");
        assertEq(amountSold, 0, "amountSold should be 0 before order starts");
        assertEq(remainingSellAmount, 1e18, "remainingSellAmount should be full amount");
        assertEq(purchasedAmount, 0, "purchasedAmount should be 0");

        // Advance time but still before start
        advanceTime(256);

        // Query again (still before start)
        (saleRateAfter, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, saleRate, "sale rate should still match");
        assertEq(amountSold, 0, "amountSold should still be 0 before order starts");
        assertEq(remainingSellAmount, 1e18, "remainingSellAmount should still be full amount");
        assertEq(purchasedAmount, 0, "purchasedAmount should still be 0");
    }

    function test_amountSold_update_before_start_then_query_after_start(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts in the future
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 32));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 16));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Advance time past start (halfway into the order)
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 2);

        // Query after order has started (halfway through)
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, saleRate, "sale rate should match");
        // Halfway through the order, half should be sold
        assertApproxEqAbs(amountSold, 0.5e18, 1e15, "amountSold should be approximately half");
        assertApproxEqAbs(remainingSellAmount, 0.5e18, 1e15, "remainingSellAmount should be approximately half");
        assertGt(purchasedAmount, 0, "purchasedAmount should be positive");
    }

    function test_amountSold_increase_sale_rate_before_start(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts in the future
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 32));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 16));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Query immediately after creation (before any time advancement)
        (uint256 saleRateBefore, uint256 amountSoldBefore,,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateBefore, initialSaleRate, "initial sale rate should match");
        assertEq(amountSoldBefore, 0, "amountSold should be 0 initially");

        // Increase the sale rate (still before start if possible)
        uint112 additionalSaleRate = orders.increaseSellAmount(id, key, 0.5e18, type(uint112).max);

        // Query after increase
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, initialSaleRate + additionalSaleRate, "sale rate should be sum of both");
        // amountSold should still be 0 or very small if we haven't advanced much past start
        assertLe(amountSold, 0.1e18, "amountSold should be small before/at start");
        assertGe(remainingSellAmount, 1.4e18, "remainingSellAmount should be close to 1.5e18");
        assertEq(purchasedAmount, 0, "purchasedAmount should be 0");

        // Advance past start (halfway into order)
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 2);

        (saleRateAfter, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, initialSaleRate + additionalSaleRate, "sale rate should still be sum");
        // Halfway through the order, half should be sold
        assertApproxEqAbs(amountSold, 0.75e18, 1e15, "amountSold should be approximately 0.75e18");
        assertApproxEqAbs(remainingSellAmount, 0.75e18, 1e15, "remainingSellAmount should be approximately 0.75e18");
    }

    function test_amountSold_decrease_sale_rate_before_start(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts in the future
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 32));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 16));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Query immediately after creation (before any time advancement)
        (uint256 saleRateBefore, uint256 amountSoldBefore,,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateBefore, initialSaleRate, "initial sale rate should match");
        assertEq(amountSoldBefore, 0, "amountSold should be 0 initially");

        // Decrease the sale rate (still before start if possible)
        orders.decreaseSaleRate(id, key, initialSaleRate / 2, address(this));

        // Query after decrease
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount, uint256 purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertApproxEqAbs(saleRateAfter, initialSaleRate / 2, 1, "sale rate should be approximately halved");
        // amountSold should still be 0 or very small if we haven't advanced much past start
        assertLe(amountSold, 0.1e18, "amountSold should be small before/at start");
        assertGe(remainingSellAmount, 0.4e18, "remainingSellAmount should be close to 0.5e18");
        assertEq(purchasedAmount, 0, "purchasedAmount should be 0");

        // Advance past start (halfway into order)
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 2);

        (saleRateAfter, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, initialSaleRate / 2, "sale rate should still be halved");
        // Halfway through the order, half should be sold
        assertApproxEqAbs(amountSold, 0.25e18, 1e15, "amountSold should be approximately 0.25e18");
        assertApproxEqAbs(remainingSellAmount, 0.25e18, 1e15, "remainingSellAmount should be approximately 0.25e18");
    }

    // Tests for amountSold computation when orders are updated after they start
    function test_amountSold_update_after_start_increase_sale_rate(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts immediately
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 32));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Advance 1/4 of the order duration
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 4);

        // Query to see amountSold before update
        (uint256 saleRateBefore, uint256 amountSoldBefore,,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateBefore, initialSaleRate, "sale rate should match initial");
        assertApproxEqAbs(amountSoldBefore, 0.25e18, 1e15, "amountSold should be approximately 0.25e18");

        // Increase sale rate after order has started
        uint112 additionalSaleRate = orders.increaseSellAmount(id, key, 0.75e18, type(uint112).max);

        // Query immediately after increase
        (uint256 saleRateAfter, uint256 amountSoldAfter, uint256 remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, initialSaleRate + additionalSaleRate, "sale rate should be sum");
        assertApproxEqAbs(amountSoldAfter, 0.25e18, 1e15, "amountSold should still be approximately 0.25e18");
        // Remaining time is 3/4 of duration, new sale rate should sell 1.75e18 total, minus 0.25e18 already sold
        assertApproxEqAbs(remainingSellAmount, 1.5e18, 1e15, "remainingSellAmount should be approximately 1.5e18");

        // Advance another 1/2 of remaining duration
        vm.warp(block.timestamp + (endTime - block.timestamp) / 2);

        (saleRateAfter, amountSoldAfter, remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        // At this point we're 5/8 through the order
        // First 1/4: sold 0.25e18, next 3/8: sold at new rate
        assertApproxEqAbs(amountSoldAfter, 1e18, 1e15, "amountSold should be approximately 1e18");
        assertApproxEqAbs(remainingSellAmount, 0.75e18, 1e15, "remainingSellAmount should be approximately 0.75e18");
    }

    function test_amountSold_update_after_start_decrease_sale_rate(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts immediately
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 32));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Advance 1/4 of the order duration
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 4);

        // Query to see amountSold before update
        (uint256 saleRateBefore, uint256 amountSoldBefore,,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateBefore, initialSaleRate, "sale rate should match initial");
        assertApproxEqAbs(amountSoldBefore, 0.25e18, 1e15, "amountSold should be approximately 0.25e18");

        // Decrease sale rate by half after order has started
        orders.decreaseSaleRate(id, key, initialSaleRate / 2, address(this));

        // Query immediately after decrease
        (uint256 saleRateAfter, uint256 amountSoldAfter, uint256 remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertApproxEqAbs(saleRateAfter, initialSaleRate / 2, 1, "sale rate should be approximately halved");
        assertApproxEqAbs(amountSoldAfter, 0.25e18, 1e15, "amountSold should still be approximately 0.25e18");
        // Remaining time is 3/4 of duration, new sale rate should sell less
        assertLe(remainingSellAmount, 0.5e18, "remainingSellAmount should be at most 0.5e18");
        assertGe(remainingSellAmount, 0.1e18, "remainingSellAmount should be at least 0.1e18");

        // Advance another 1/2 of remaining duration
        vm.warp(block.timestamp + (endTime - block.timestamp) / 2);

        (saleRateAfter, amountSoldAfter, remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        // At this point we're 5/8 through the order
        assertApproxEqAbs(amountSoldAfter, 0.375e18, 1e17, "amountSold should be approximately 0.375e18");
        assertApproxEqAbs(remainingSellAmount, 0.125e18, 1e17, "remainingSellAmount should be approximately 0.125e18");
    }

    function test_amountSold_multiple_updates_after_start(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts immediately
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 48));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        uint256 duration = endTime - startTime;

        // Advance 1/6 of duration
        vm.warp(startTime + duration / 6);

        (, uint256 amountSold1,,) = orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        assertApproxEqAbs(amountSold1, uint256(1e18) / 6, 2e16, "amountSold should be approximately 1/6");

        // Increase sale rate
        orders.increaseSellAmount(id, key, 0.5e18, type(uint112).max);

        // Advance another 1/6 of duration (total 1/3)
        vm.warp(startTime + duration / 3);

        (, uint256 amountSold2,,) = orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        // After 1/3 of duration with rate changes, should have sold a reasonable amount
        assertGt(amountSold2, 0.3e18, "amountSold should be greater than 0.3e18");
        assertLt(amountSold2, 0.6e18, "amountSold should be less than 0.6e18");

        // Decrease sale rate
        orders.decreaseSaleRate(id, key, initialSaleRate / 2, address(this));

        // Advance another 1/3 of duration (total 2/3)
        vm.warp(startTime + 2 * duration / 3);

        (, uint256 amountSold3, uint256 remainingSellAmount3,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);
        // The math is complex due to changing rates, but we can verify it's in a reasonable range
        assertApproxEqAbs(amountSold3, 0.866666666666666666e18, 1e17, "amountSold after third period");
        assertApproxEqAbs(remainingSellAmount3, 0.4e18, 1e17, "remainingSellAmount after third period");
    }

    function test_amountSold_update_at_exact_start_time(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts in the future
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 16));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 16));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Advance exactly to start time
        vm.warp(startTime);

        // Update at exact start time
        orders.increaseSellAmount(id, key, 0.5e18, type(uint112).max);

        // Query immediately
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertGt(saleRateAfter, initialSaleRate, "sale rate should be increased");
        assertEq(amountSold, 0, "amountSold should be 0 at exact start time");
        assertEq(remainingSellAmount, 1.5e18, "remainingSellAmount should be 1.5e18");

        // Advance halfway through the order
        uint256 duration = endTime - startTime;
        vm.warp(startTime + duration / 2);

        (saleRateAfter, amountSold, remainingSellAmount,) = orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertApproxEqAbs(amountSold, 0.75e18, 1e15, "amountSold should be approximately 0.75e18");
        assertApproxEqAbs(remainingSellAmount, 0.75e18, 1e15, "remainingSellAmount should be approximately 0.75e18");
    }

    function test_amountSold_update_after_order_ends(uint64 time) public {
        time = boundTime(time, 1);
        vm.warp(time);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18);

        token0.approve(address(orders), type(uint256).max);

        // Create an order that starts immediately
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 16));
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });
        (uint256 id, uint112 initialSaleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);

        // Advance past end time
        vm.warp(endTime + 10);

        // Query after order ends
        (uint256 saleRateAfter, uint256 amountSold, uint256 remainingSellAmount,) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, initialSaleRate, "sale rate should match");
        assertApproxEqAbs(amountSold, 1e18, 1, "amountSold should be approximately full amount");
        assertEq(remainingSellAmount, 0, "remainingSellAmount should be 0");

        // Try to update after end - should revert
        vm.expectRevert(IOrders.OrderAlreadyEnded.selector);
        orders.increaseSellAmount(id, key, 0.5e18, type(uint112).max);
    }

    /// @notice Test documenting that proceeds must be collected before stopping an order
    /// @dev This demonstrates the correct usage pattern: collect proceeds before decreasing sale rate
    function test_collectProceeds_before_stop_order_correct() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);

        // Let the order run for half the duration
        advanceTime(128);

        // CORRECT ORDER: Collect proceeds BEFORE stopping the order
        uint128 proceedsBeforeStop = orders.collectProceeds(id, key, address(this));

        // Now stop the order
        uint112 refund = orders.decreaseSaleRate(id, key, saleRate, address(this));

        // Try to collect proceeds again after stopping
        uint128 proceedsAfterStop = orders.collectProceeds(id, key, address(this));

        // We should have collected some proceeds before stopping
        assertGt(proceedsBeforeStop, 0, "Should have collected proceeds before stopping");

        // After stopping, there should be no additional proceeds
        assertEq(proceedsAfterStop, 0, "Should have no proceeds after stopping since we already collected");

        // We should have gotten a refund for the unsold tokens
        assertGt(refund, 0, "Should have received refund for unsold tokens");
    }

    /// @notice Test documenting that proceeds cannot be collected after stopping an order
    /// @dev This is intended behavior - the TWAMM extension cannot assume proceeds should be withdrawn
    ///      Users must collect proceeds before calling decreaseSaleRate to stop their order
    function test_collectProceeds_after_stop_order_loses_proceeds() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);

        // Let the order run for half the duration
        advanceTime(128);

        // INCORRECT ORDER: Stop the order BEFORE collecting proceeds
        uint112 refund = orders.decreaseSaleRate(id, key, saleRate, address(this));

        // Now try to collect proceeds after stopping
        uint128 proceedsAfterStop = orders.collectProceeds(id, key, address(this));

        // We should have gotten a refund for the unsold tokens
        assertGt(refund, 0, "Should have received refund for unsold tokens");

        // INTENDED BEHAVIOR: Proceeds cannot be collected after stopping the order
        // proceedsAfterStop will be 0 even though the order ran for 8 seconds
        // This is by design - users must collect proceeds before calling decreaseSaleRate
        assertEq(proceedsAfterStop, 0, "Proceeds cannot be collected after stopping order (intended behavior)");
    }

    /// @notice Test documenting the importance of operation order when stopping orders
    /// @dev Demonstrates that proceeds must be collected before stopping to avoid losing them
    ///      This is intended behavior to ensure the TWAMM extension doesn't make assumptions
    function test_proceeds_lost_comparison() public {
        vm.warp(1);

        uint64 fee = uint64((uint256(5) << 64) / 100);
        int32 tick = 0;

        PoolKey memory poolKey = createTwammPool({fee: fee, tick: tick});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 10000, 10000);

        token0.approve(address(orders), type(uint256).max);

        // Create two identical orders at the same time in the same pool
        OrderKey memory key1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        (uint256 id1, uint112 saleRate1) = orders.mintAndIncreaseSellAmount(key1, 100, type(uint112).max);

        OrderKey memory key2 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
        });
        (uint256 id2, uint112 saleRate2) = orders.mintAndIncreaseSellAmount(key2, 100, type(uint112).max);

        // Let both orders run for 8 seconds (half the duration)
        advanceTime(8);

        // Scenario 1: Correct order (collect then stop)
        uint128 proceedsCorrectOrder = orders.collectProceeds(id1, key1, address(this));
        orders.decreaseSaleRate(id1, key1, saleRate1, address(this));

        // Scenario 2: Incorrect order (stop then collect)
        orders.decreaseSaleRate(id2, key2, saleRate2, address(this));
        uint128 proceedsIncorrectOrder = orders.collectProceeds(id2, key2, address(this));

        // The correct order collected proceeds, but the incorrect order cannot collect them after stopping
        assertGt(proceedsCorrectOrder, 0, "Correct order: should have collected proceeds");
        assertEq(proceedsIncorrectOrder, 0, "Incorrect order: proceeds cannot be collected after stopping");

        // This demonstrates the intended behavior: same order parameters, same duration, but different results
        // based solely on the order of operations. Users must collect proceeds before stopping orders.
        assertTrue(
            proceedsCorrectOrder > proceedsIncorrectOrder,
            "INTENDED BEHAVIOR: Proceeds cannot be collected after stopping order"
        );
    }

    function test_gas_costs_execute_virtual_orders_switch_sell_direction() public {
        vm.warp(0);

        uint64 fee = 0;
        PoolKey memory poolKey = createTwammPool({fee: fee, tick: 0});

        {
            token0.approve(address(orders), type(uint256).max);
            OrderKey memory key = OrderKey({
                token0: poolKey.token0,
                token1: poolKey.token1,
                config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: 0, _endTime: 256})
            });
            orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);
        }
        {
            token1.approve(address(orders), type(uint256).max);
            OrderKey memory key = OrderKey({
                token0: poolKey.token0,
                token1: poolKey.token1,
                config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: 256, _endTime: 512})
            });
            orders.mintAndIncreaseSellAmount(key, 100, type(uint112).max);
        }

        vm.warp(512);

        coolAllContracts();
        twamm.lockAndExecuteVirtualOrders(poolKey);
        vm.snapshotGasLastCall("lockAndExecuteVirtualOrders switch sell direction");
    }
}
