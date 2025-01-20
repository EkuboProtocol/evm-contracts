// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, Bounds} from "../src/types/keys.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";

contract PositionsTest is FullTest {
    function test_metadata() public view {
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/1");
    }

    function test_mintAndDeposit(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);

        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        (uint256 id, uint128 liquidity) = positions.mintAndDeposit(poolKey, bounds, 100, 100, 0);
        assertGt(id, 0);
        assertGt(liquidity, 0);
        assertEq(token0.balanceOf(address(core)), 100);
        assertEq(token1.balanceOf(address(core)), 100);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity, address(this));

        // original 100, rounded down, minus the 50% fee
        assertEq(amount0, 49);
        assertEq(amount1, 49);
    }

    function test_collectFees_amount0(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token0.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 49);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity, address(this));

        assertEq(amount0, 74);
        assertEq(amount1, 25);
    }

    function test_collectFees_amount1(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token1.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100})
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 49);

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity, address(this));

        assertEq(amount0, 25);
        assertEq(amount1, 74);
    }

    function test_collectFeesAndWithdraw(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        token0.approve(address(router), 100);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100})
        );

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50})
        );

        (uint128 amount0, uint128 amount1) =
            positions.collectFeesAndWithdraw(id, poolKey, Bounds(-100, 100), liquidity, address(this));
        assertEq(amount0, 111);
        assertEq(amount1, 61);
    }

    function test_mintAndDeposit_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        positions.mintAndDeposit(poolKey, bounds, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit");
    }

    function test_mintAndDeposit_eth_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        positions.mintAndDeposit{value: 100}(poolKey, bounds, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit eth");
    }
}
