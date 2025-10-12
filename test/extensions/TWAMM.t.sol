// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolKey} from "../../src/types/poolKey.sol";
import {
    createConcentratedPoolConfig,
    createFullRangePoolConfig,
    createStableswapPoolConfig
} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {FullTest} from "../FullTest.sol";
import {ITWAMM, TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {OrderKey} from "../../src/interfaces/extensions/ITWAMM.sol";
import {createOrderConfig} from "../../src/types/orderConfig.sol";
import {TWAMMStorageLayout} from "../../src/libraries/TWAMMStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {Core} from "../../src/Core.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../../src/libraries/TWAMMLib.sol";
import {Test} from "forge-std/Test.sol";
import {searchForNextInitializedTime} from "../../src/math/timeBitmap.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA} from "../../src/math/time.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {createTimeInfo} from "../../src/types/timeInfo.sol";
import {TwammPoolState} from "../../src/types/twammPoolState.sol";
import {TimeInfo} from "../../src/types/timeInfo.sol";
import {Orders} from "../../src/Orders.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {ILocker} from "../../src/interfaces/IFlashAccountant.sol";

abstract contract BaseTWAMMTest is FullTest {
    TWAMM internal twamm;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), deployAddress);
        twamm = TWAMM(deployAddress);
    }

    function boundTime(uint256 time, uint32 offset) internal pure returns (uint64) {
        return uint64(((bound(time, offset, type(uint64).max - type(uint32).max - 2 * offset) / 16) * 16) + offset);
    }

    function createTwammPool(uint64 fee, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, createFullRangePoolConfig(fee, address(twamm)));
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(twamm));
    }
}

contract TWAMMTest is BaseTWAMMTest {
    using TWAMMLib for *;

    function test_createPool_fails_concentrated_liquidity() public {
        vm.expectRevert(ITWAMM.FullRangePoolOnly.selector);
        createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(0, 1, address(twamm)));
    }

    function test_createPool(uint256 time) public {
        vm.warp(time);
        PoolKey memory key = createTwammPool(100, 0);
        (uint32 lvoe, uint112 srt0, uint112 srt1) = twamm.poolState(key.toPoolId()).parse();
        assertEq(lvoe, uint32(time));
        assertEq(srt0, 0);
        assertEq(srt1, 0);
    }

    /// forge-config: default.isolate = true
    function test_createPool() public {
        coolAllContracts();
        createTwammPool(100, 0);
        vm.snapshotGasLastCall("create pool");
    }

    function test_lockAndExecuteVirtualOrders_initialized_but_state_zero() public {
        // recreate the conditions as described in TWAMM#_executeVirtualOrdersFromWithinLock
        vm.warp(1 << 32);
        PoolKey memory key = createTwammPool(100, 0);

        assertEq(TwammPoolState.unwrap(twamm.poolState(key.toPoolId())), bytes32(0));

        twamm.lockAndExecuteVirtualOrders(key);
    }

    function test_lockAndExecuteVirtualOrders_not_initialized() public {
        PoolKey memory key = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createFullRangePoolConfig(0, address(twamm))
        });
        vm.expectRevert(ITWAMM.PoolNotInitialized.selector);
        twamm.lockAndExecuteVirtualOrders(key);
    }

    function test_lockAndExecuteVirtualOrders_initialized_but_from_other_extension() public {
        PoolKey memory key = createFullRangePool(0, 0);
        vm.expectRevert(ITWAMM.PoolNotInitialized.selector);
        twamm.lockAndExecuteVirtualOrders(key);
    }
}

contract TWAMMStableswapTest is BaseTWAMMTest, ILocker {
    using CoreLib for *;
    using TWAMMLib for *;

    // State for locked callback
    string private currentAction;
    bytes private currentData;

    function createStableswapTwammPool(uint64 fee, uint8 amplification, int32 centerTick, int32 tick)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(
            address(token0),
            address(token1),
            tick,
            createStableswapPoolConfig(fee, amplification, centerTick, address(twamm))
        );
    }

    function test_createPool_stableswap() public {
        uint256 time = 1000;
        vm.warp(time);

        // Create a stableswap pool with amplification factor 10 and center tick 0
        PoolKey memory key = createStableswapTwammPool(100, 10, 0, 0);

        (uint32 lvoe, uint112 srt0, uint112 srt1) = twamm.poolState(key.toPoolId()).parse();
        assertEq(lvoe, uint32(time));
        assertEq(srt0, 0);
        assertEq(srt1, 0);
    }

    function locked_6416899205(uint256) external {
        if (keccak256(bytes(currentAction)) == keccak256("createAndExecuteOrders")) {
            (
                PoolKey memory poolKey,
                bytes32 salt1,
                bytes32 salt2,
                OrderKey memory orderKey0,
                OrderKey memory orderKey1,
                int112 saleRate0,
                int112 saleRate1
            ) = abi.decode(currentData, (PoolKey, bytes32, bytes32, OrderKey, OrderKey, int112, int112));

            // Create orders (only if sale rate is non-zero)
            if (saleRate0 != 0) {
                int256 amount0 = core.updateSaleRate(twamm, salt1, orderKey0, saleRate0);
                if (amount0 > 0) token0.transfer(address(core), uint256(amount0));
            }
            if (saleRate1 != 0) {
                int256 amount1 = core.updateSaleRate(twamm, salt2, orderKey1, saleRate1);
                if (amount1 > 0) token1.transfer(address(core), uint256(amount1));
            }
        } else if (keccak256(bytes(currentAction)) == keccak256("collectProceeds")) {
            (bytes32 salt, OrderKey memory orderKey) = abi.decode(currentData, (bytes32, OrderKey));

            uint128 proceeds = core.collectProceeds(twamm, salt, orderKey);

            // Store proceeds in currentData for retrieval
            currentData = abi.encode(proceeds);
        }
    }

    function test_stableswap_orders_settle_at_sale_rate_ratio_when_out_of_range() public {
        uint64 time = boundTime(1000, 1);
        vm.warp(time);

        // Create a stableswap pool with amplification factor 10
        // This creates a narrow liquidity range around tick 0
        uint64 fee = 0;
        uint8 amplification = 10;
        int32 centerTick = 0;

        PoolKey memory poolKey = createStableswapTwammPool(fee, amplification, centerTick, 0);

        // Add a small amount of liquidity in the stableswap range
        // With amplification 10, the liquidity range is narrow
        (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
        createPosition(poolKey, lower, upper, 1000, 1000);

        // Create orders with 2:1 sale rate ratio (selling 2x token1 vs token0)
        bytes32 salt = bytes32(uint256(1));
        OrderKey memory orderKey0 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 63})
        });
        OrderKey memory orderKey1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 63})
        });

        // Deposit tokens and create orders
        token0.approve(address(core), type(uint256).max);
        token1.approve(address(core), type(uint256).max);

        // Create orders using locked callback
        currentAction = "createAndExecuteOrders";
        currentData = abi.encode(
            poolKey,
            salt,
            bytes32(uint256(2)),
            orderKey0,
            orderKey1,
            int112(uint112((1e18 << 32) / 64)),
            int112(uint112((2e18 << 32) / 64))
        );
        core.lock();

        // Advance time - orders will push price out of liquidity range
        // When liquidity becomes 0, orders settle at the ratio of sale rates
        advanceTime(64);

        // Collect proceeds
        currentAction = "collectProceeds";
        currentData = abi.encode(salt, orderKey0);
        core.lock();
        uint128 proceeds0 = abi.decode(currentData, (uint128));

        currentData = abi.encode(bytes32(uint256(2)), orderKey1);
        core.lock();
        uint128 proceeds1 = abi.decode(currentData, (uint128));

        // When liquidity is 0, orders should settle at the ratio of sale rates
        // Sale rate ratio is 2:1 (token1:token0), so:
        // - Order selling 1e18 token0 should receive ~2e18 token1
        // - Order selling 2e18 token1 should receive ~1e18 token0

        // Check that the ratio is approximately 2:1
        assertGt(proceeds0, 1.9e18, "Order 0 should receive close to 2e18");
        assertLt(proceeds0, 2.1e18, "Order 0 should not receive much more than 2e18");

        assertGt(proceeds1, 0.9e18, "Order 1 should receive close to 1e18");
        assertLt(proceeds1, 1.1e18, "Order 1 should not receive much more than 1e18");
    }

    function test_stableswap_zero_sale_rate_one_side_receives_nothing() public {
        uint64 time = boundTime(1000, 1);
        vm.warp(time);

        // Create a stableswap pool
        uint64 fee = 0;
        uint8 amplification = 10;
        int32 centerTick = 0;

        PoolKey memory poolKey = createStableswapTwammPool(fee, amplification, centerTick, 0);

        // Add liquidity in the stableswap range
        (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
        createPosition(poolKey, lower, upper, 1000, 1000);

        // Create order selling only token0 (no token1 being sold)
        bytes32 salt = bytes32(uint256(1));
        OrderKey memory orderKey0 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: time - 1, _endTime: time + 63})
        });

        token0.approve(address(core), type(uint256).max);

        // Create order using locked callback
        currentAction = "createAndExecuteOrders";
        currentData = abi.encode(
            poolKey,
            salt,
            bytes32(0), // unused salt2
            orderKey0,
            orderKey0, // unused orderKey1
            int112(uint112((1e18 << 32) / 64)),
            int112(0) // zero sale rate for token1
        );
        core.lock();

        // Advance time
        advanceTime(64);

        // When there's zero sale rate on the token1 side and liquidity is 0,
        // the token0 order should receive no output tokens
        currentAction = "collectProceeds";
        currentData = abi.encode(salt, orderKey0);
        core.lock();
        uint128 proceeds0 = abi.decode(currentData, (uint128));

        // The order should receive 0 or very close to 0 tokens
        assertLt(proceeds0, 1e10, "Order should receive essentially nothing when counterparty has zero sale rate");
    }

    function test_stableswap_both_sides_zero_when_out_of_range() public {
        uint64 time = boundTime(1000, 1);
        vm.warp(time);

        // Create a stableswap pool
        uint64 fee = 0;
        uint8 amplification = 10;
        int32 centerTick = 0;

        PoolKey memory poolKey = createStableswapTwammPool(fee, amplification, centerTick, 0);

        // Add liquidity in the stableswap range
        (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
        createPosition(poolKey, lower, upper, 1000, 1000);

        // Create order selling only token1 (no token0 being sold)
        bytes32 salt = bytes32(uint256(1));
        OrderKey memory orderKey1 = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: true, _startTime: time - 1, _endTime: time + 63})
        });

        token1.approve(address(core), type(uint256).max);

        // Create order using locked callback
        currentAction = "createAndExecuteOrders";
        currentData = abi.encode(
            poolKey,
            bytes32(0), // unused salt1
            salt,
            orderKey1, // unused orderKey0
            orderKey1,
            int112(0), // zero sale rate for token0
            int112(uint112((1e18 << 32) / 64))
        );
        core.lock();

        // Advance time
        advanceTime(64);

        // When there's zero sale rate on the token0 side and liquidity is 0,
        // the token1 order should receive no output tokens
        currentAction = "collectProceeds";
        currentData = abi.encode(salt, orderKey1);
        core.lock();
        uint128 proceeds1 = abi.decode(currentData, (uint128));

        // The order should receive 0 or very close to 0 tokens
        assertLt(proceeds1, 1e10, "Order should receive essentially nothing when counterparty has zero sale rate");
    }
}

// Note the inheritance order matters because Test contains storage variables
contract TWAMMInternalMethodsTests is TWAMM, Test {
    constructor() TWAMM(new Core()) {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }

    function test_orderKeyToPoolKey(OrderKey memory orderKey, address twamm) public pure {
        PoolKey memory pk = orderKey.toPoolKey(twamm);

        assertEq(pk.token0, orderKey.token0);
        assertEq(pk.token1, orderKey.token1);
        assertEq(pk.config.fee(), orderKey.config.fee());
        assertEq(pk.config.concentratedTickSpacing(), 0);
        assertEq(pk.config.extension(), twamm);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta_overflows() public {
        vm.expectRevert();
        _addConstrainSaleRateDelta(1, type(int256).max);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta_underflows() public {
        vm.expectRevert();
        _addConstrainSaleRateDelta(-1, type(int256).min);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta(int112 saleRateDelta, int256 saleRateDeltaChange) public {
        // prevents running into arithmetic overflow/underflow errors
        saleRateDeltaChange =
            bound(saleRateDeltaChange, type(int256).min - type(int112).min, type(int256).max - type(int112).max);

        int256 result = int256(saleRateDelta) + saleRateDeltaChange;
        if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            vm.expectRevert(MaxSaleRateDeltaPerTime.selector);
        }

        assertEq(_addConstrainSaleRateDelta(saleRateDelta, saleRateDeltaChange), result);
    }

    function getRewardRateInside(PoolId poolId, uint64 startTime, uint64 endTime, bool isToken1)
        private
        view
        returns (uint256)
    {
        return getRewardRateInside(
            poolId, createOrderConfig({_fee: 0, _startTime: startTime, _endTime: endTime, _isToken1: isToken1})
        );
    }

    function test_getRewardRateInside_token0() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        vm.warp(99);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        vm.warp(150);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        StorageSlot rewardRatesSlot = TWAMMStorageLayout.poolRewardRatesSlot(poolId);

        rewardRatesSlot.storeTwo(bytes32(uint256(100)), bytes32(uint256(75)));
        assertEq(getRewardRateInside(poolId, 100, 200, true), 100);

        rewardRatesSlot.storeTwo(bytes32(uint256(300)), bytes32(uint256(450)));
        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 200).storeTwo(bytes32(uint256(150)), bytes32(uint256(150)));
        vm.warp(250);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 150);

        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 100).storeTwo(bytes32(uint256(50)), bytes32(uint256(100)));
        assertEq(getRewardRateInside(poolId, 100, 200, true), 100);
    }

    function test_getRewardRateInside_at_end_time() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 100).storeTwo(bytes32(uint256(25)), bytes32(uint256(30)));
        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 200).storeTwo(bytes32(uint256(50)), bytes32(uint256(75)));
        vm.warp(200);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 25);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 45);
    }

    function test_getRewardRateInside_token1() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        vm.warp(99);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        vm.warp(150);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        StorageSlot rewardRatesSlot = TWAMMStorageLayout.poolRewardRatesSlot(poolId);

        rewardRatesSlot.storeTwo(bytes32(uint256(100)), bytes32(uint256(75)));
        assertEq(getRewardRateInside(poolId, 100, 200, false), 75);

        rewardRatesSlot.storeTwo(bytes32(uint256(300)), bytes32(uint256(450)));
        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 200).storeTwo(bytes32(uint256(150)), bytes32(uint256(160)));
        vm.warp(250);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 160);

        TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 100).storeTwo(bytes32(uint256(50)), bytes32(uint256(100)));
        assertEq(getRewardRateInside(poolId, 100, 200, false), 60);
    }

    function test_updateTime_flips_time() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});

        {
            (uint32 numOrders, int112 delta0, int112 delta1) =
                TimeInfo.wrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, 96).load()).parse();

            assertEq(numOrders, 1);
            assertEq(delta0, 100);
            assertEq(delta1, 0);
        }

        StorageSlot initializedTimesBitmap = TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId);

        (uint256 time, bool initialized) = searchForNextInitializedTime({
            slot: initializedTimesBitmap,
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = searchForNextInitializedTime({
            slot: initializedTimesBitmap,
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 1000);
        assertEq(initialized, false);
    }

    function test_updateTime_flips_time_two_orders_one_removed() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 55, isToken1: true, numOrdersChange: 1});

        {
            (uint32 numOrders, int112 delta0, int112 delta1) =
                TimeInfo.wrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, 96).load()).parse();

            assertEq(numOrders, 2);
            assertEq(delta0, 100);
            assertEq(delta1, 55);
        }

        StorageSlot initializedTimesBitmap = TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId);

        (uint256 time, bool initialized) = searchForNextInitializedTime({
            slot: initializedTimesBitmap,
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = searchForNextInitializedTime({
            slot: initializedTimesBitmap,
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_max_num_orders_exceeded() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        TWAMMStorageLayout.poolTimeInfosSlot(poolId, 96).store(TimeInfo.unwrap(createTimeInfo(type(uint32).max, 0, 0)));
        vm.expectRevert(ITWAMM.TimeNumOrdersOverflow.selector);
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_subtract_orders_from_zero() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        vm.expectRevert(ITWAMM.TimeNumOrdersOverflow.selector);
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: -1});
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_max_sale_rate_delta_exceeded() public {
        PoolId poolId = PoolId.wrap(bytes32(0));
        StorageSlot slot = TWAMMStorageLayout.poolTimeInfosSlot(poolId, 96);

        slot.store(TimeInfo.unwrap(createTimeInfo(0, type(int112).max, 0)));
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 1, isToken1: false, numOrdersChange: 0});

        slot.store(TimeInfo.unwrap(createTimeInfo(0, 0, type(int112).max)));
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 1, isToken1: true, numOrdersChange: 0});

        slot.store(TimeInfo.unwrap(createTimeInfo(0, type(int112).min, 0)));
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: -1, isToken1: false, numOrdersChange: 0});

        slot.store(TimeInfo.unwrap(createTimeInfo(0, 0, type(int112).min)));
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: -1, isToken1: true, numOrdersChange: 0});
    }

    function test_updateTime_flip_time_overflows_uint32() public {
        PoolId poolId = PoolId.wrap(bytes32(0));

        uint256 time = uint256(type(uint32).max) + 17;
        assert(time % 16 == 0);

        _updateTime({poolId: poolId, time: time, saleRateDelta: 1, isToken1: false, numOrdersChange: 1});

        (uint256 nextTime, bool initialized) = searchForNextInitializedTime({
            slot: TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId),
            lastVirtualOrderExecutionTime: time,
            fromTime: time - 15,
            untilTime: time + 15
        });
        assertEq(nextTime, time);
        assertEq(initialized, true);
    }
}
