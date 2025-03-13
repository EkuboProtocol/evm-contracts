// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {UpdatePositionParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../../src/types/poolKey.sol";
import {PositionKey, Bounds} from "../../src/types/positionKey.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {
    MIN_TICK,
    MAX_TICK,
    MAX_TICK_SPACING,
    FULL_RANGE_ONLY_TICK_SPACING,
    NATIVE_TOKEN_ADDRESS
} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {Oracle, oracleCallPoints} from "../../src/extensions/Oracle.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FullRangeOnlyPool} from "../../src/types/positionKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {console} from "forge-std/console.sol";
import {BaseOracleTest} from "../extensions/Oracle.t.sol";

contract OracleLibTest is BaseOracleTest {
    using OracleLib for *;

    function test_getEarliestSnapshotTimestamp_single_snapshot(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), type(uint256).max);

        PoolKey memory poolKey = createOraclePool(address(token0), 0);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime);

        advanceTime(5);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime);

        movePrice(poolKey, 5);
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime + 5);
    }

    function test_getEarliestSnapshotTimestamp_multiple_snapshots(uint256 startTime) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint32).max);
        vm.warp(startTime);

        oracle.expandCapacity(address(token0), 2);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), type(uint256).max);

        PoolKey memory poolKey = createOraclePool(address(token0), 0);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime);

        advanceTime(5);

        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime);

        movePrice(poolKey, 1000);
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime);

        advanceTime(10);
        movePrice(poolKey, 0);
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime + 5);

        oracle.expandCapacity(address(token0), 5);
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime + 5);

        advanceTime(20);
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime + 5);
        movePrice(poolKey, -1);

        // it does  not start increasing yet
        assertEq(oracle.getEarliestSnapshotTimestamp(address(token0)), startTime + 15);
    }
}
