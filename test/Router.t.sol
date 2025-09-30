// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolId} from "../src/types/poolId.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "../src/types/sqrtRatio.sol";
import {
    FULL_RANGE_ONLY_TICK_SPACING,
    MIN_TICK,
    MAX_TICK,
    MAX_TICK_SPACING,
    NATIVE_TOKEN_ADDRESS
} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {FullTest} from "./FullTest.sol";
import {LiquidityDeltaOverflow} from "../src/math/liquidity.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {Vm} from "forge-std/Test.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolState} from "../src/types/poolState.sol";

contract RouterTest is FullTest {
    using CoreLib for *;

    function test_noop_sqrt_ratio_limit_equals_price_token0_out(int32 tick) public {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey = createPool({tick: tick, fee: 1 << 63, tickSpacing: 100});

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(tick), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: type(int128).min}),
            type(int256).min
        );
        assertEq(delta0, 0);
        assertEq(delta1, 0);
    }

    function test_noop_sqrt_ratio_limit_equals_price_token1_out(int32 tick) public {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey = createPool({tick: tick, fee: 1 << 63, tickSpacing: 100});

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(tick), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: type(int128).min}),
            type(int256).min
        );
        assertEq(delta0, 0);
        assertEq(delta1, 0);
    }

    function test_reverts_sqrtRatioLimit_wrong_direction(int32 tick) public {
        tick = int32(bound(tick, MIN_TICK + 1, MAX_TICK - 1));
        PoolKey memory poolKey = createPool({tick: tick, fee: 1 << 63, tickSpacing: 100});

        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(tick - 1), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: type(int128).min}),
            type(int256).min
        );

        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(tick + 1), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: type(int128).min}),
            type(int256).min
        );
    }

    function test_basicSwap_token0_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), 100);

        (int128 delta0, int128 delta1,) =
            router.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: false, amount: 100, skipAhead: 0});
        assertEq(delta0, 100);
        assertEq(delta1, -49);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, 100);
        assertEq(delta1, -49);
    }

    function test_basicSwap_token0_in_with_recipient(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), 100);
        router.swap(poolKey, false, 100, SqrtRatio.wrap(0), 0, type(int256).min, address(0xdeadbeef));
        assertEq(token1.balanceOf(address(0xdeadbeef)), 49);
    }

    function test_basicSwap_token0_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token1.approve(address(router), 202);

        (int128 delta0, int128 delta1,) = router.quote({
            poolKey: poolKey,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            isToken1: false,
            amount: -100,
            skipAhead: 0
        });
        assertEq(delta0, -100);
        assertEq(delta1, 202);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, -100);
        assertEq(delta1, 202);
    }

    function test_basicSwap_token0_out_with_recipient(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token1.approve(address(router), 202);

        router.swap(poolKey, false, -100, SqrtRatio.wrap(0), 0, type(int256).min, address(0xdeadbeef));
        assertEq(token0.balanceOf(address(0xdeadbeef)), 100);
    }

    function test_basicSwap_token1_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token1.approve(address(router), 100);

        (int128 delta0, int128 delta1,) =
            router.quote({poolKey: poolKey, sqrtRatioLimit: MAX_SQRT_RATIO, isToken1: true, amount: 100, skipAhead: 0});
        assertEq(delta0, -49);
        assertEq(delta1, 100);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, -49);
        assertEq(delta1, 100);
    }

    function test_basicSwap_token1_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), 202);

        (int128 delta0, int128 delta1,) =
            router.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: true, amount: -100, skipAhead: 0});
        assertEq(delta0, 202);
        assertEq(delta1, -100);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, 202);
        assertEq(delta1, -100);
    }

    function test_basicSwap_token0_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            50
        );
    }

    function test_basicSwap_token0_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            -200
        );
    }

    function test_swap_delta_overflows_int128_container_token0_in() public {
        PoolKey memory poolKey = createPool({tick: MAX_TICK, fee: 0, tickSpacing: 0});
        createPosition(poolKey, MIN_TICK, MAX_TICK, type(uint128).max >> 1, type(uint128).max >> 1);
        createPosition(poolKey, MIN_TICK, MAX_TICK, type(uint128).max >> 1, type(uint128).max >> 1);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: type(int128).max}),
            type(int256).min
        );
        assertEq(delta0, type(int128).max);
        assertEq(delta1, type(int128).min);
    }

    function test_swap_delta_overflows_int128_container_token1_in() public {
        PoolKey memory poolKey = createPool({tick: MIN_TICK, fee: 0, tickSpacing: 0});
        createPosition(poolKey, MIN_TICK, MAX_TICK, type(uint128).max >> 1, type(uint128).max >> 1);
        createPosition(poolKey, MIN_TICK, MAX_TICK, type(uint128).max >> 1, type(uint128).max >> 1);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: type(int128).max}),
            type(int256).min
        );
        assertEq(delta0, type(int128).min);
        assertEq(delta1, type(int128).max);
    }

    function test_swap_liquidity_overflow_token0() public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 1});

        (, uint128 liquidity0) = createPosition(poolKey, -1, 5, (type(uint128).max >> 20), (type(uint128).max >> 20));
        (, uint128 liquidity1) = createPosition(poolKey, 0, 6, (type(uint128).max >> 20), (type(uint128).max >> 20));
        (, uint128 liquidity2) = createPosition(poolKey, 1, 7, (type(uint128).max >> 20), (type(uint128).max >> 20));

        assertGt(uint256(liquidity0) + liquidity1 + liquidity2, type(uint128).max);

        vm.expectRevert(LiquidityDeltaOverflow.selector);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(2), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: type(int128).max}),
            type(int256).min
        );
    }

    function test_swap_liquidity_overflow_token1() public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 1});

        (, uint128 liquidity0) = createPosition(poolKey, -5, 1, (type(uint128).max >> 20), (type(uint128).max >> 20));
        (, uint128 liquidity1) = createPosition(poolKey, -6, 0, (type(uint128).max >> 20), (type(uint128).max >> 20));
        (, uint128 liquidity2) = createPosition(poolKey, -7, -1, (type(uint128).max >> 20), (type(uint128).max >> 20));

        assertGt(uint256(liquidity0) + liquidity1 + liquidity2, type(uint128).max);

        vm.expectRevert(LiquidityDeltaOverflow.selector);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(-2), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: type(int128).max}),
            type(int256).min
        );
    }

    function test_basicSwap_token1_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            50
        );
    }

    function test_basicSwap_token1_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            -200
        );
    }

    function test_basicSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token1.approve(address(router), 202);

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, -100);
        assertEq(delta1, 202);
    }

    function test_multihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), 100);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: 100})), type(int256).min);
        assertEq(d[0].amount0, 100);
        assertEq(d[0].amount1, -49);
        assertEq(d[1].amount0, -24);
        assertEq(d[1].amount1, 49);
    }

    function test_multihopSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: -100})), type(int256).min);
        assertEq(d[0].amount0, -100);
        assertEq(d[0].amount1, 202);
        assertEq(d[1].amount0, 406);
        assertEq(d[1].amount1, -202);
    }

    function test_multiMultihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route0 = new RouteNode[](2);
        route0[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route0[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        RouteNode[] memory route1 = new RouteNode[](2);
        route1[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route1[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route0, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route1, TokenAmount({token: address(token0), amount: -100}));

        Delta[][] memory d = router.multiMultihopSwap(swaps, type(int256).min);
        assertEq(d[0][0].amount0, 100);
        assertEq(d[0][0].amount1, -49);
        assertEq(d[0][1].amount0, -24);
        assertEq(d[0][1].amount1, 49);

        assertEq(d[1][0].amount0, -100);
        assertEq(d[1][0].amount1, 202);
        assertEq(d[1][1].amount0, 406);
        assertEq(d[1][1].amount1, -202);
    }

    function test_multiMultihopSwap_slippage_input(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: 100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, 49, 48));
        router.multiMultihopSwap(swaps, 49);
        // 48 works
        router.multiMultihopSwap(swaps, 48);
    }

    function test_multiMultihopSwap_eth_payment() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 150}));
        swaps[1] = Swap(route, TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 50}));

        // eth multihop swap
        router.multiMultihopSwap{value: 200}(swaps, type(int256).min);
    }

    function test_multiMultihopSwap_eth_middle_of_route() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token1), amount: 150}));
        swaps[1] = Swap(route, TokenAmount({token: address(token1), amount: 50}));

        token1.approve(address(router), type(uint256).max);
        router.multiMultihopSwap(swaps, type(int256).min);
    }

    function test_multiMultihopSwap_slippage_input_reverts_diff_tokens(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token1), amount: 100}));

        vm.expectRevert(abi.encodeWithSelector(Router.TokensMismatch.selector, 1));
        router.multiMultihopSwap(swaps, type(int256).min);
    }

    function test_multiMultihopSwap_slippage_output(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: -100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: -100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, -807, -808));
        router.multiMultihopSwap(swaps, -807);
        // -808 works
        router.multiMultihopSwap(swaps, -808);
    }

    function test_validation_Swaps() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](1);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token1), amount: 100}));

        vm.expectRevert();
        router.multiMultihopSwap(swaps, type(int256).min);
    }

    function test_coreEmitsSwapLogs() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        (, uint128 liquidity) = createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);
        route[1] = RouteNode(poolKey, SqrtRatio.wrap(0), 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: -100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: -100}));

        vm.recordLogs();
        Delta[][] memory deltas = router.multiMultihopSwap(swaps, -808);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 6);
        // swap events emit have 0 topics and come from core
        for (uint256 i = 0; i < 4; i++) {
            assertEq(logs[i].emitter, address(core));
            assertEq(logs[i].topics.length, 0);
            assertEq(logs[i].data.length, 116);
            address locker = address(bytes20(LibBytes.load(logs[i].data, 0)));
            assertEq(locker, address(router));
            bytes32 poolId = LibBytes.load(logs[i].data, 20);
            assertEq(poolId, PoolId.unwrap(poolKey.toPoolId()));

            assertEq(PoolState.wrap(LibBytes.load(logs[i].data, 84)).liquidity(), liquidity);
        }

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 52)))), deltas[0][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 68)))), deltas[0][0].amount1);
        assertEq(
            PoolState.wrap(LibBytes.load(logs[0].data, 84)).sqrtRatio().toFixed(),
            340284068297894840612141065344447938560
        );
        assertEq(PoolState.wrap(LibBytes.load(logs[0].data, 84)).tick(), 9);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 52)))), deltas[0][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 68)))), deltas[0][1].amount1);
        assertEq(
            PoolState.wrap(LibBytes.load(logs[1].data, 84)).sqrtRatio().toFixed(),
            340280631533626427978182251206462668800
        );
        assertEq(PoolState.wrap(LibBytes.load(logs[1].data, 84)).tick(), -11);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 52)))), deltas[1][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 68)))), deltas[1][0].amount1);
        assertEq(
            PoolState.wrap(LibBytes.load(logs[2].data, 84)).sqrtRatio().toFixed(),
            340282332893229288559183010384991748096
        );
        assertEq(PoolState.wrap(LibBytes.load(logs[2].data, 84)).tick(), -1);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 52)))), deltas[1][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 68)))), deltas[1][1].amount1);
        assertEq(
            PoolState.wrap(LibBytes.load(logs[3].data, 84)).sqrtRatio().toFixed(),
            340278930156329870109718837961959669760
        );
        assertEq(PoolState.wrap(LibBytes.load(logs[3].data, 84)).tick(), -21);
    }

    function test_basicSwap_price_2x(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(693147, 1 << 63, 100, callPoints);
        createPosition(poolKey, 693100, 693200, 1000, 1000);

        token0.approve(address(router), 100);

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, 100);
        // approximately 1x after fee
        assertEq(delta1, -99);
    }

    /// forge-config: default.isolate = true
    function test_swap_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token0.approve(address(router), 100);

        coolAllContracts();
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 token0 for token1");
    }

    /// forge-config: default.isolate = true
    function test_swap_token_for_eth_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);

        token1.approve(address(router), 100);

        coolAllContracts();
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 token0 for eth");
    }

    /// forge-config: default.isolate = true
    function test_swap_cross_tick_eth_for_token1() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);
        createPosition(poolKey, -200, 200, 1000, 1000);

        coolAllContracts();
        router.swap{value: 30000}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: tickToSqrtRatio(-250), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 30000}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap crossing two ticks eth for token1");

        assertEq(core.poolState(poolKey.toPoolId()).tick(), -250);
    }

    /// forge-config: default.isolate = true
    function test_swap_cross_tick_token1_for_eth() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);
        createPosition(poolKey, -200, 200, 1000, 1000);

        token1.approve(address(router), type(uint256).max);

        coolAllContracts();
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 3500}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap crossing one tick token1 for eth");

        assertEq(core.poolState(poolKey.toPoolId()).tick(), 149);
    }

    /// forge-config: default.isolate = true
    function test_swap_eth_for_token_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        createPosition(poolKey, -100, 100, 1000, 1000);

        coolAllContracts();
        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of eth for token");
    }

    /// forge-config: default.isolate = true
    function test_swap_eth_for_token_full_range_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, FULL_RANGE_ONLY_TICK_SPACING);
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 1000);

        coolAllContracts();
        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of eth for token full range");
    }

    /// forge-config: default.isolate = true
    function test_swap_token_for_eth_full_range_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, FULL_RANGE_ONLY_TICK_SPACING);
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1000, 1000);

        token1.approve(address(router), 100);
        coolAllContracts();
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of token for eth full range");
    }

    function test_swap_full_range_to_max_price() public {
        PoolKey memory poolKey = createPool(MAX_TICK - 1, 0, FULL_RANGE_ONLY_TICK_SPACING);

        (, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1, 1e36);
        assertNotEq(liquidity, 0);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: -1,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min
        });

        assertEq(delta0, 0);
        assertEq(delta1, 499999875000098127000483558015);

        // reaches max tick but does not change liquidity
        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidityAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertEq(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MAX_SQRT_RATIO));
        assertEq(tick, MAX_TICK);
        assertEq(liquidityAfter, liquidity);
    }

    function test_swap_full_range_to_min_price() public {
        PoolKey memory poolKey = createPool(MIN_TICK + 1, 0, FULL_RANGE_ONLY_TICK_SPACING);

        (, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1e36, 1);
        assertNotEq(liquidity, 0);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: -1,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min
        });

        assertEq(delta0, 499999875000098127108899679808);
        assertEq(delta1, 0);

        // reaches max tick but does not change liquidity
        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidityAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertEq(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MIN_SQRT_RATIO));
        // crosses the min tick, but liquidity is still not zero
        assertEq(tick, MIN_TICK - 1);
        assertEq(liquidityAfter, liquidity);
    }

    function test_swap_max_spacing_to_max_price() public {
        PoolKey memory poolKey = createPool(MAX_TICK - 1, 0, MAX_TICK_SPACING);

        (, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1, 1e36);
        assertNotEq(liquidity, 0);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: -1,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min
        });

        assertEq(delta0, 0);
        assertEq(delta1, 499999875000098127000483558015);

        // reaches max tick but does not change liquidity
        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidityAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertEq(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MAX_SQRT_RATIO));
        assertEq(tick, MAX_TICK);
        assertEq(liquidityAfter, 0);
    }

    function test_swap_max_spacing_to_min_price() public {
        PoolKey memory poolKey = createPool(MIN_TICK + 1, 0, MAX_TICK_SPACING);

        (, uint128 liquidity) = createPosition(poolKey, MIN_TICK, MAX_TICK, 1e36, 1);
        assertNotEq(liquidity, 0);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: -1,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min
        });

        assertEq(delta0, 499999875000098127108899679808);
        assertEq(delta1, 0);

        // reaches max tick but does not change liquidity
        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidityAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertEq(SqrtRatio.unwrap(sqrtRatio), SqrtRatio.unwrap(MIN_SQRT_RATIO));
        // crosses the min tick, but liquidity is still not zero
        assertEq(tick, MIN_TICK - 1);
        assertEq(liquidityAfter, 0);
    }
}
