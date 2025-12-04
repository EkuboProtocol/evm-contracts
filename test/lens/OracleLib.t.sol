// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {PoolKey} from "../../src/types/poolKey.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
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
