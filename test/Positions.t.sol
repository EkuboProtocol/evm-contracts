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

        positions.pay(address(token0), 100);
        positions.pay(address(token1), 100);

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
