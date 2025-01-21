// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, Bounds} from "../src/types/keys.sol";
import {FullTest} from "./FullTest.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";

contract RouterTest is FullTest {
    function test_basicSwap_token0_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
        );
        assertEq(d.amount0, 100);
        assertEq(d.amount1, -49);
    }

    function test_basicSwap_token0_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100})
        );
        assertEq(d.amount0, -100);
        assertEq(d.amount1, 202);
    }

    function test_basicSwap_token1_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100})
        );
        assertEq(d.amount0, -49);
        assertEq(d.amount1, 100);
    }

    function test_basicSwap_token1_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 202);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100})
        );
        assertEq(d.amount0, 202);
        assertEq(d.amount1, -100);
    }

    function test_basicSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100})
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

        Delta[] memory d = router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: 100})));
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

        Delta[] memory d = router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: -100})));
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

        Delta[][] memory d = router.multiMultihopSwap(swaps);
        assertEq(d[0][0].amount0, 100);
        assertEq(d[0][0].amount1, -49);
        assertEq(d[0][1].amount0, -24);
        assertEq(d[0][1].amount1, 49);

        assertEq(d[1][0].amount0, -100);
        assertEq(d[1][0].amount1, 202);
        assertEq(d[1][1].amount0, 406);
        assertEq(d[1][1].amount1, -202);
    }

    function test_basicSwap_price_2x(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(693147, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(693100, 693200), 1000, 1000);

        token0.approve(address(router), 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
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
            TokenAmount({token: address(token0), amount: 100})
        );
        vm.snapshotGasLastCall("swap 100 token0");
    }

    function test_swap_eth_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
        );
        vm.snapshotGasLastCall("swap 100 wei of eth");
    }
}
