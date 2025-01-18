// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, Bounds} from "../src/types/keys.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";

contract RouterTest is FullTest {
    function test_basicSwap(CallPoints memory callPoints) public {
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
