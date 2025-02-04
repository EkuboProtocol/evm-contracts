// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {FullTest} from "./FullTest.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {Vm} from "forge-std/Test.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";

contract RouterTest is FullTest {
    function test_basicSwap_token0_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: false, amount: 100, skipAhead: 0});
        assertEq(delta0, 100);
        assertEq(delta1, -49);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(d.amount0, 100);
        assertEq(d.amount1, -49);
    }

    function test_basicSwap_token0_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        (int128 delta0, int128 delta1) = quoter.quote({
            poolKey: poolKey,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            isToken1: false,
            amount: -100,
            skipAhead: 0
        });
        assertEq(delta0, -100);
        assertEq(delta1, 202);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(d.amount0, -100);
        assertEq(d.amount1, 202);
    }

    function test_basicSwap_token1_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 100);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MAX_SQRT_RATIO, isToken1: true, amount: 100, skipAhead: 0});
        assertEq(delta0, -49);
        assertEq(delta1, 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        assertEq(d.amount0, -49);
        assertEq(d.amount1, 100);
    }

    function test_basicSwap_token1_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 202);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: true, amount: -100, skipAhead: 0});
        assertEq(delta0, 202);
        assertEq(delta1, -100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            type(int256).min
        );
        assertEq(d.amount0, 202);
        assertEq(d.amount1, -100);
    }

    function test_basicSwap_token0_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            50
        );
    }

    function test_basicSwap_token0_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            -200
        );
    }

    function test_basicSwap_token1_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            50
        );
    }

    function test_basicSwap_token1_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            -200
        );
    }

    function test_basicSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(d.amount0, -100);
        assertEq(d.amount1, 202);
    }

    function test_multihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: 100})), type(int256).min);
        assertEq(d[0].amount0, 100);
        assertEq(d[0].amount1, -49);
        assertEq(d[1].amount0, -24);
        assertEq(d[1].amount1, 49);
    }

    function test_multihopSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: -100})), type(int256).min);
        assertEq(d[0].amount0, -100);
        assertEq(d[0].amount1, 202);
        assertEq(d[1].amount0, 406);
        assertEq(d[1].amount1, -202);
    }

    function test_multiMultihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route0 = new RouteNode[](2);
        route0[0] = RouteNode(poolKey, 0, 0);
        route0[1] = RouteNode(poolKey, 0, 0);

        RouteNode[] memory route1 = new RouteNode[](2);
        route1[0] = RouteNode(poolKey, 0, 0);
        route1[1] = RouteNode(poolKey, 0, 0);

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
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: 100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, 49, 48));
        router.multiMultihopSwap(swaps, 49);
        // 48 works
        router.multiMultihopSwap(swaps, 48);
    }

    function test_multiMultihopSwap_slippage_output(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: -100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: -100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, -807, -808));
        router.multiMultihopSwap(swaps, -807);
        // -808 works
        router.multiMultihopSwap(swaps, -808);
    }

    function test_coreEmitsSwapLogs() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        (, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

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
            assertEq(logs[i].data.length, 124);
            address locker = address(bytes20(LibBytes.load(logs[i].data, 0)));
            assertEq(locker, address(router));
            bytes32 poolId = LibBytes.load(logs[i].data, 20);
            assertEq(poolId, poolKey.toPoolId());

            assertEq(uint256(LibBytes.load(logs[i].data, 84)) >> 128, liquidity);

            uint256 sqrtRatio = uint256(LibBytes.load(logs[i].data, 100)) >> 96;
            // sqrt ratio between the bounds since we didn't go out of range
            assertLe(sqrtRatio, tickToSqrtRatio(100));
            assertGe(sqrtRatio, tickToSqrtRatio(-100));

            int32 tick = int32(uint32(bytes4(LibBytes.load(logs[i].data, 120))));
            assertLe(tick, 100);
            assertGe(tick, -100);
            assertNotEq(tick, 0);
        }

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 52)))), deltas[0][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 68)))), deltas[0][0].amount1);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 52)))), deltas[0][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 68)))), deltas[0][1].amount1);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 52)))), deltas[1][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 68)))), deltas[1][0].amount1);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 52)))), deltas[1][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 68)))), deltas[1][1].amount1);
    }

    function test_basicSwap_price_2x(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(693147, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(693100, 693200), 1000, 1000);

        token0.approve(address(router), 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(d.amount0, 100);
        // approximately 1x after fee
        assertEq(d.amount1, -99);
    }

    function test_swap_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 token0");
    }

    function test_swap_eth_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of eth");
    }
}
