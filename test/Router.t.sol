// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {Positions, ITokenURIGenerator} from "../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey, Bounds} from "../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";
import {LibString} from "solady/utils/LibString.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TestToken} from "./TestToken.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";

contract RouterTest is FullTest {
    function test_basicSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);
        router.pay(address(token0), 100);

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
        router.pay(address(token0), 100);

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
        router.pay(address(token0), 100);

        Delta memory d = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
        );
        vm.snapshotGasLastCall("swap 100 token0");
    }
}
