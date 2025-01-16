// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {Positions, ITokenURIGenerator} from "../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey, Bounds} from "../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";
import {LibString} from "solady/utils/LibString.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TestToken} from "./TestToken.sol";

contract PositionsTest is Test {
    address owner = address(0xdeadbeef);
    WETH public weth;
    ITokenURIGenerator public tokenURIGenerator;
    Core public core;
    Positions public positions;

    TestToken public token0;
    TestToken public token1;

    function setUp() public {
        weth = new WETH();
        core = new Core(owner);
        tokenURIGenerator = new BaseURLTokenURIGenerator(owner, "ekubo://positions/");
        positions = new Positions(core, tokenURIGenerator, weth);
        TestToken tokenA = new TestToken();
        TestToken tokenB = new TestToken();
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function test_metadata() public view {
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/1");
    }

    function test_mintAndDeposit() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            fee: 1 << 127,
            tickSpacing: 100,
            extension: address(0)
        });

        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        positions.pay(address(token0), 100);
        positions.pay(address(token1), 100);

        positions.maybeInitializePool(poolKey, 0);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        (uint256 id, uint128 liquidity) = positions.mintAndDeposit(poolKey, bounds, 100, 100, 0);
        assertGt(id, 0);
        assertGt(liquidity, 0);
        assertEq(token0.balanceOf(address(core)), 100);
        assertEq(token1.balanceOf(address(core)), 100);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity, address(this), 0, 0);

        // original 100, rounded down, minus the 50% fee
        assertEq(amount0, 49);
        assertEq(amount1, 49);
    }
}
