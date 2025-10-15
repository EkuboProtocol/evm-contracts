// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {PoolKey} from "../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {ITWAMM, OrderKey} from "../src/interfaces/extensions/ITWAMM.sol";
import {Router} from "../src/Router.sol";
import {isPriceIncreasing} from "../src/math/isPriceIncreasing.sol";
import {nextValidTime} from "../src/math/time.sol";
import {Amount0DeltaOverflow, Amount1DeltaOverflow} from "../src/math/delta.sol";
import {MAX_TICK, MIN_TICK} from "../src/math/constants.sol";
import {AmountBeforeFeeOverflow} from "../src/math/fee.sol";
import {SaleRateOverflow} from "../src/math/twamm.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Positions} from "../src/Positions.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {IPositions} from "../src/interfaces/IPositions.sol";
import {Orders} from "../src/Orders.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {TestToken} from "./TestToken.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityDeltaOverflow} from "../src/math/liquidity.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {createOrderConfig} from "../src/types/orderConfig.sol";

contract Handler is StdUtils, StdAssertions {
    using CoreLib for *;

    uint256 immutable positionId;
    uint256 immutable ordersId;

    struct ActivePosition {
        PoolKey poolKey;
        int32 tickLower;
        int32 tickUpper;
        uint128 liquidity;
    }

    struct OrderInfo {
        OrderKey orderKey;
        uint112 saleRate;
    }

    struct Balances {
        int256 amount0;
        int256 amount1;
    }

    ICore immutable core;
    Positions immutable positions;
    Router immutable router;
    TestToken immutable token0;
    TestToken immutable token1;
    Orders immutable orders;
    Vm vm;

    ActivePosition[] activePositions;
    OrderInfo[] activeOrders;
    PoolKey[] allPoolKeys;

    uint256 totalAdvanced;

    constructor(
        ICore _core,
        Orders _orders,
        Positions _positions,
        Router _router,
        TestToken _token0,
        TestToken _token1,
        Vm _vm
    ) {
        core = _core;
        positions = _positions;
        orders = _orders;
        router = _router;
        token0 = _token0;
        token1 = _token1;
        vm = _vm;
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);
        positionId = positions.mint();
        ordersId = orders.mint();

        // this means we will cross the uint32 max boundary in our tests via advanceTime
        vm.warp(type(uint32).max - type(uint16).max);
    }

    function advanceTime(uint32 by) public {
        totalAdvanced += by;
        if (totalAdvanced > type(uint32).max) {
            ITWAMM twamm = orders.TWAMM_EXTENSION();
            // first do the execute on all pools, because we assume all pools are executed at least this often
            for (uint256 i = 0; i < activeOrders.length; i++) {
                twamm.lockAndExecuteVirtualOrders(activeOrders[i].orderKey.toPoolKey(address(twamm)));
            }
            totalAdvanced = by;
        }
        vm.warp(vm.getBlockTimestamp() + by);
    }

    function createNewPool(uint64 fee, int32 tick) public {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey = PoolKey(
            address(token0), address(token1), createFullRangePoolConfig(fee, address(orders.TWAMM_EXTENSION()))
        );
        (bool initialized, SqrtRatio sqrtRatio) = positions.maybeInitializePool(poolKey, tick);
        assertNotEq(SqrtRatio.unwrap(sqrtRatio), 0);
        if (initialized) allPoolKeys.push(poolKey);
    }

    modifier ifPoolExists() {
        if (allPoolKeys.length == 0) return;
        _;
    }

    error UnexpectedError(bytes data);

    function deposit(uint256 poolKeyIndex, uint128 amount0, uint128 amount1) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];

        try positions.deposit(
            positionId, poolKey, MIN_TICK, MAX_TICK, amount0, amount1, 0
        ) returns (uint128 liquidity, uint128, uint128) {
            if (liquidity > 0) {
                activePositions.push(ActivePosition(poolKey, MIN_TICK, MAX_TICK, liquidity));
            }
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != IPositions.DepositOverflow.selector && sig != SafeCastLib.Overflow.selector && sig != 0x4e487b71
                    && sig != FixedPointMathLib.FullMulDivFailed.selector && sig != LiquidityDeltaOverflow.selector
                    && sig != Amount1DeltaOverflow.selector && sig != Amount0DeltaOverflow.selector
                    && sig != SafeTransferLib.TransferFromFailed.selector
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function withdraw(uint256 index, uint128 liquidity, bool collectFees) public ifPoolExists {
        if (activePositions.length == 0) return;
        ActivePosition storage p = activePositions[bound(index, 0, activePositions.length - 1)];

        liquidity = uint128(bound(liquidity, 0, p.liquidity));

        try positions.withdraw(
            positionId, p.poolKey, p.tickLower, p.tickUpper, liquidity, address(this), collectFees
        ) returns (uint128, uint128) {
            p.liquidity -= liquidity;
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            if (
                // arithmetic overflow can definitely happen in positions contract if liquidity + fees > uint128
                sig != SafeCastLib.Overflow.selector && sig != Amount1DeltaOverflow.selector
                    && sig != Amount0DeltaOverflow.selector && sig != 0x4e487b71
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function swap(uint256 poolKeyIndex, int128 amount, bool isToken1, uint256 skipAhead) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];

        bool increasing = isPriceIncreasing(amount, isToken1);

        SqrtRatio sqrtRatioLimit;

        if (increasing) {
            sqrtRatioLimit = MAX_SQRT_RATIO;
        } else {
            sqrtRatioLimit = MIN_SQRT_RATIO;
        }

        skipAhead = bound(skipAhead, 0, type(uint8).max);

        try router.swap{
            gas: 15000000
        }({
            poolKey: poolKey, sqrtRatioLimit: sqrtRatioLimit, skipAhead: skipAhead, isToken1: isToken1, amount: amount
        }) returns (PoolBalanceUpdate) {}
        catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            // 0xffffffff and 0x00000000 are evm errors for out of gas
            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != Router.PartialSwapsDisallowed.selector && sig != 0xffffffff && sig != 0x00000000
                    && sig != Amount1DeltaOverflow.selector && sig != Amount0DeltaOverflow.selector
                    && sig != AmountBeforeFeeOverflow.selector && sig != 0x4e487b71
                    && sig != SafeCastLib.Overflow.selector && sig != SafeTransferLib.TransferFromFailed.selector
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function createOrder(
        uint256 poolKeyIndex,
        uint16 startDelay,
        uint24 approximateDuration,
        uint112 amount,
        bool isToken1
    ) public ifPoolExists {
        amount = isToken1
            ? uint112(bound(amount, 0, SafeTransferLib.balanceOf(address(token1), address(this))))
            : uint112(bound(amount, 0, SafeTransferLib.balanceOf(address(token0), address(this))));

        if (amount == 0) return;

        approximateDuration = uint24(bound(approximateDuration, 16, type(uint24).max));

        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];
        uint256 startTime;
        uint256 endTime;

        if (startDelay == 0) {
            startTime = 0;
            endTime = nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + approximateDuration - 1);
        } else {
            startTime = nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + startDelay - 1);
            endTime = nextValidTime(vm.getBlockTimestamp(), startTime + approximateDuration);
        }

        if (startTime > type(uint64).max || endTime > type(uint64).max) {
            return;
        }

        OrderKey memory orderKey = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({
                _fee: poolKey.config.fee(),
                _isToken1: isToken1,
                _startTime: uint64(startTime),
                _endTime: uint64(endTime)
            })
        });

        try orders.increaseSellAmount(ordersId, orderKey, amount, type(uint112).max) returns (uint112 saleRate) {
            activeOrders.push(OrderInfo({orderKey: orderKey, saleRate: saleRate}));
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            // 0xc902643d == SaleRateDeltaOverflow()
            if (sig != SaleRateOverflow.selector && sig != ITWAMM.MaxSaleRateDeltaPerTime.selector && sig != 0xc902643d)
            {
                revert UnexpectedError(err);
            }
        }
    }

    function decreaseOrderSaleRate(uint256 orderIndex, uint112 amount) public ifPoolExists {
        if (activeOrders.length == 0) return;
        OrderInfo storage order = activeOrders[bound(orderIndex, 0, activeOrders.length - 1)];
        amount = uint112(bound(amount, 0, order.saleRate));

        try orders.decreaseSaleRate(ordersId, order.orderKey, amount, address(this)) returns (uint112) {
            order.saleRate -= amount;
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            if (sig != IOrders.OrderAlreadyEnded.selector) {
                revert UnexpectedError(err);
            }
        }
    }

    function collectOrderProceeds(uint256 orderIndex) public ifPoolExists {
        if (activeOrders.length == 0) return;
        OrderInfo storage order = activeOrders[bound(orderIndex, 0, activeOrders.length - 1)];

        try orders.collectProceeds(ordersId, order.orderKey, address(this)) returns (uint128) {}
        catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            revert UnexpectedError(err);
        }
    }

    function checkAllPoolsHaveValidPriceAndTick() public view {
        for (uint256 i = 0; i < allPoolKeys.length; i++) {
            PoolKey memory poolKey = allPoolKeys[i];

            (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(poolKey.toPoolId()).parse();

            assertGe(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MIN_SQRT_RATIO));
            assertLe(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MAX_SQRT_RATIO));
            assertTrue(sqrtRatio.isValid());
            assertGe(tick, MIN_TICK - 1);
            assertLe(tick, MAX_TICK + 1);
        }
    }
}

contract TWAMMInvariantTest is BaseOrdersTest {
    Handler handler;

    function setUp() public override {
        BaseOrdersTest.setUp();

        handler = new Handler(core, orders, positions, router, token0, token1, vm);

        // funding core makes it easier for pools to become insolvent randomly if there is a bug
        token0.transfer(address(core), type(uint128).max);
        token1.transfer(address(core), type(uint128).max);
        // for the purpose of our twamm invariants, we assume tokens do not have a total supply g.t. type(uint128).max
        token0.transfer(address(handler), type(uint128).max);
        token1.transfer(address(handler), type(uint128).max);

        targetContract(address(handler));

        bytes4[] memory excluded = new bytes4[](1);
        excluded[0] = Handler.checkAllPoolsHaveValidPriceAndTick.selector;
        excludeSelector(FuzzSelector(address(handler), excluded));
    }

    function invariant_allPoolsHaveValidStates() public view {
        handler.checkAllPoolsHaveValidPriceAndTick();
    }
}
