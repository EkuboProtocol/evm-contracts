// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {CallPoints, byteToCallPoints} from "../../src/types/callPoints.sol";

contract CallPointsTest is Test {
    function test_byteToCallPoints_none() public pure {
        CallPoints memory cp = byteToCallPoints(0);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_all() public pure {
        CallPoints memory cp = byteToCallPoints(255);
        assertEq(cp.beforeInitializePool, true);
        assertEq(cp.afterInitializePool, true);
        assertEq(cp.beforeSwap, true);
        assertEq(cp.afterSwap, true);
        assertEq(cp.beforeUpdatePosition, true);
        assertEq(cp.afterUpdatePosition, true);
        assertEq(cp.beforeCollectFees, true);
        assertEq(cp.afterCollectFees, true);
    }

    function test_byteToCallPoints_beforeInitializePool() public pure {
        CallPoints memory cp = byteToCallPoints(1);
        assertEq(cp.beforeInitializePool, true);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_afterInitializePool() public pure {
        CallPoints memory cp = byteToCallPoints(128);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, true);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_beforeSwap() public pure {
        CallPoints memory cp = byteToCallPoints(64);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, true);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_afterSwap() public pure {
        CallPoints memory cp = byteToCallPoints(32);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, true);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_beforeUpdatePosition() public pure {
        CallPoints memory cp = byteToCallPoints(16);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, true);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_afterUpdatePosition() public pure {
        CallPoints memory cp = byteToCallPoints(8);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, true);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_beforeCollectFees() public pure {
        CallPoints memory cp = byteToCallPoints(4);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, true);
        assertEq(cp.afterCollectFees, false);
    }

    function test_byteToCallPoints_afterCollectFees() public pure {
        CallPoints memory cp = byteToCallPoints(2);
        assertEq(cp.beforeInitializePool, false);
        assertEq(cp.afterInitializePool, false);
        assertEq(cp.beforeSwap, false);
        assertEq(cp.afterSwap, false);
        assertEq(cp.beforeUpdatePosition, false);
        assertEq(cp.afterUpdatePosition, false);
        assertEq(cp.beforeCollectFees, false);
        assertEq(cp.afterCollectFees, true);
    }

    function test_byteToCallPoints_any_integer_does_not_revert(uint8 b) public pure {
        byteToCallPoints(b);
    }

    function test_callPoints_toUint8(CallPoints memory callPoints) public pure {
        assertTrue(callPoints.eq(byteToCallPoints(callPoints.toUint8())));
    }
}
