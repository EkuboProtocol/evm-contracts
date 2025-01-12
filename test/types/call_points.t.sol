// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CallPoints, byteToCallPoints} from "../../src/types/call_points.sol";

contract CallPointsTest is Test {
    function test_byteToCallPoints_none() public pure {
        CallPoints memory cp = byteToCallPoints(0);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_all() public pure {
        CallPoints memory cp = byteToCallPoints(255);
        assertEq(cp.before_initialize_pool, true);
        assertEq(cp.after_initialize_pool, true);
        assertEq(cp.before_swap, true);
        assertEq(cp.after_swap, true);
        assertEq(cp.before_update_position, true);
        assertEq(cp.after_update_position, true);
        assertEq(cp.before_collect_fees, true);
        assertEq(cp.after_collect_fees, true);
    }

    function test_byteToCallPoints_before_initialize_pool() public pure {
        CallPoints memory cp = byteToCallPoints(1);
        assertEq(cp.before_initialize_pool, true);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_after_initialize_pool() public pure {
        CallPoints memory cp = byteToCallPoints(128);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, true);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_before_swap() public pure {
        CallPoints memory cp = byteToCallPoints(64);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, true);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_after_swap() public pure {
        CallPoints memory cp = byteToCallPoints(32);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, true);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_before_update_position() public pure {
        CallPoints memory cp = byteToCallPoints(16);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, true);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_after_update_position() public pure {
        CallPoints memory cp = byteToCallPoints(8);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, true);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_before_collect_fees() public pure {
        CallPoints memory cp = byteToCallPoints(4);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, true);
        assertEq(cp.after_collect_fees, false);
    }

    function test_byteToCallPoints_after_collect_fees() public pure {
        CallPoints memory cp = byteToCallPoints(2);
        assertEq(cp.before_initialize_pool, false);
        assertEq(cp.after_initialize_pool, false);
        assertEq(cp.before_swap, false);
        assertEq(cp.after_swap, false);
        assertEq(cp.before_update_position, false);
        assertEq(cp.after_update_position, false);
        assertEq(cp.before_collect_fees, false);
        assertEq(cp.after_collect_fees, true);
    }

    function test_byteToCallPoints_any_integer_does_not_revert(uint8 b) public pure {
        byteToCallPoints(b);
    }
}
