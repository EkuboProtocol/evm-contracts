// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core} from "../../src/Core.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {Positions, ITokenURIGenerator} from "../../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../../src/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey, Bounds} from "../../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../../src/math/ticks.sol";
import {LibString} from "solady/utils/LibString.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TestToken} from "../TestToken.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle} from "../../src/extensions/Oracle.sol";
import {toUint8} from "../../src/types/callPoints.sol";

contract OracleTest is FullTest {
    Oracle oracle;

    function setUp() public override {
        FullTest.setUp();
        address deployAddress = address(
            uint160(
                CallPoints({
                    beforeInitializePool: true,
                    afterInitializePool: false,
                    beforeUpdatePosition: true,
                    afterUpdatePosition: false,
                    beforeSwap: true,
                    afterSwap: false,
                    beforeCollectFees: false,
                    afterCollectFees: false
                }).toUint8()
            ) << 152
        );
        deployCodeTo("Oracle.sol", abi.encode(core, address(token0)), deployAddress);
        oracle = Oracle(deployAddress);
    }

    function test_getImmutables() public view {
        assertEq(oracle.oracleToken(), address(token0));
        assertEq(oracle.timestampOffset(), uint64(block.timestamp));
    }

    function test_createPool() public {
        createPool(0, 0, MAX_TICK_SPACING, address(oracle));
        assertEq(oracle.snapshotCount(address(token1)), 1);
        (uint32 secondsSinceOffset, uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
            oracle.snapshots(address(token1), 0);
        assertEq(secondsSinceOffset, 0);
        assertEq(secondsPerLiquidityCumulative, 0);
        assertEq(tickCumulative, 0);
    }
}
