// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio} from "../src/types/sqrtRatio.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {TWAMM, OrderKey} from "../src/extensions/TWAMM.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {isPriceIncreasing} from "../src/math/swap.sol";
import {Amount0DeltaOverflow, Amount1DeltaOverflow} from "../src/math/delta.sol";
import {MAX_TICK, MIN_TICK, MAX_TICK_SPACING, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {AmountBeforeFeeOverflow} from "../src/math/fee.sol";
import {SaleRateOverflow} from "../src/math/twamm.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Positions} from "../src/Positions.sol";
import {Orders} from "../src/Orders.sol";
import {TestToken} from "./TestToken.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityDeltaOverflow} from "../src/math/liquidity.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBit} from "solady/utils/LibBit.sol";

contract Handler is StdUtils, StdAssertions {
    using CoreLib for *;

    uint256 immutable positionId;
    uint256 immutable ordersId;

    struct ActivePosition {
        PoolKey poolKey;
        Bounds bounds;
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

    uint32 totalAdvanced;

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
        by = uint32(bound(by, 1, type(uint16).max));
        vm.warp(vm.getBlockTimestamp() + by);
    }

    function createNewPool(uint64 fee, int32 tick) public {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey = PoolKey(
            address(token0), address(token1), toConfig(fee, FULL_RANGE_ONLY_TICK_SPACING, address(orders.twamm()))
        );
        (bool initialized, SqrtRatio sqrtRatio) = positions.maybeInitializePool(poolKey, tick);
        assertNotEq(SqrtRatio.unwrap(sqrtRatio), 0);
        if (initialized) allPoolKeys.push(poolKey);
    }

    function withdrawProtocolFees(bool isToken1, uint256 amount) external {
        address token = isToken1 ? address(token1) : address(token0);

        amount = bound(amount, 0, core.protocolFeesCollected(token));
        core.withdrawProtocolFees(address(this), token, amount);
    }

    modifier ifPoolExists() {
        if (allPoolKeys.length == 0) return;
        _;
    }

    error UnexpectedError(bytes data);

    function deposit(uint256 poolKeyIndex, uint128 amount0, uint128 amount1) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];

        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);

        try positions.deposit(positionId, poolKey, bounds, amount0, amount1, 0) returns (
            uint128 liquidity, uint128, uint128
        ) {
            if (liquidity > 0) {
                activePositions.push(ActivePosition(poolKey, bounds, liquidity));
            }
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != Positions.DepositOverflow.selector && sig != SafeCastLib.Overflow.selector && sig != 0x4e487b71
                    && sig != FixedPointMathLib.FullMulDivFailed.selector && sig != LiquidityDeltaOverflow.selector
                    && sig != Amount1DeltaOverflow.selector && sig != Amount0DeltaOverflow.selector
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function withdraw(uint256 index, uint128 liquidity, bool collectFees) public ifPoolExists {
        if (activePositions.length == 0) return;
        ActivePosition storage p = activePositions[bound(index, 0, activePositions.length - 1)];

        liquidity = uint128(bound(liquidity, 0, p.liquidity));

        try positions.withdraw(positionId, p.poolKey, p.bounds, liquidity, address(this), collectFees) returns (
            uint128, uint128
        ) {
            p.liquidity -= liquidity;
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            if (
                // arithmetic overflow can definitely happen in positions contract if liquidity + fees > uint128
                sig != ICore.MustCollectFeesBeforeWithdrawingAllLiquidity.selector
                    && sig != SafeCastLib.Overflow.selector && sig != Amount1DeltaOverflow.selector
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

        try router.swap{gas: 15000000}({
            poolKey: poolKey,
            sqrtRatioLimit: sqrtRatioLimit,
            skipAhead: skipAhead,
            isToken1: isToken1,
            amount: amount
        }) returns (int128, int128) {} catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            // 0xffffffff and 0x00000000 are evm errors for out of gas
            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != Router.PartialSwapsDisallowed.selector && sig != 0xffffffff && sig != 0x00000000
                    && sig != Amount1DeltaOverflow.selector && sig != Amount0DeltaOverflow.selector
                    && sig != AmountBeforeFeeOverflow.selector && sig != 0x4e487b71 && sig != SafeCastLib.Overflow.selector
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function nextValidTime(uint256 time) private view returns (uint256) {
        uint256 t = vm.getBlockTimestamp();
        assert(time >= t);
        if (time - t < 16) {
            return ((time + 15) / 16) * 16;
        } else {
            uint256 stepSize = uint256(1) << FixedPointMathLib.max(4, (((LibBit.fls(time - t)) / 4) * 4));
            uint256 validTime0 = ((time + stepSize - 1) / stepSize) * stepSize;
            uint256 nextStepSize = uint256(1) << FixedPointMathLib.max(4, (((LibBit.fls(validTime0 - t)) / 4) * 4));
            return ((time + nextStepSize - 1) / nextStepSize) * nextStepSize;
        }
    }

    function createOrder(
        uint256 poolKeyIndex,
        uint16 startDelay,
        uint24 approximateDuration,
        uint112 amount,
        bool isToken1
    ) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];
        uint256 startTime;
        uint256 endTime;

        approximateDuration = uint24(bound(approximateDuration, 16, type(uint24).max));

        if (startDelay == 0) {
            startTime = 0;
            endTime = nextValidTime(vm.getBlockTimestamp() + approximateDuration);
        } else {
            startTime = nextValidTime(vm.getBlockTimestamp() + startDelay);
            endTime = nextValidTime(startTime + approximateDuration);
        }

        (address sellToken, address buyToken) =
            isToken1 ? (poolKey.token1, poolKey.token0) : (poolKey.token0, poolKey.token1);

        OrderKey memory orderKey = OrderKey({
            sellToken: sellToken,
            buyToken: buyToken,
            fee: poolKey.fee(),
            startTime: startTime,
            endTime: endTime
        });

        try orders.increaseSellAmount(ordersId, orderKey, amount, type(uint112).max) returns (uint112 saleRate) {
            activeOrders.push(OrderInfo({orderKey: orderKey, saleRate: saleRate}));
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            // 0xc902643d == SaleRateDeltaOverflow()
            if (sig != SaleRateOverflow.selector && sig != TWAMM.MaxSaleRateDeltaPerTime.selector && sig != 0xc902643d)
            {
                revert UnexpectedError(err);
            }
        }
    }

    function checkAllPoolsHaveValidPriceAndTick() public view {
        for (uint256 i = 0; i < allPoolKeys.length; i++) {
            PoolKey memory poolKey = allPoolKeys[i];

            (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(poolKey.toPoolId());

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
        vm.prank(owner);
        core.transferOwnership(address(handler));
        vm.stopPrank();

        // funding core makes it easier for pools to become insolvent randomly if there is a bug
        token0.transfer(address(core), type(uint128).max);
        token1.transfer(address(core), type(uint128).max);
        token0.transfer(address(handler), type(uint256).max - type(uint128).max);
        token1.transfer(address(handler), type(uint256).max - type(uint128).max);

        targetContract(address(handler));
    }

    function invariant_allPoolsHaveValidStates() public view {
        handler.checkAllPoolsHaveValidPriceAndTick();
    }
}
