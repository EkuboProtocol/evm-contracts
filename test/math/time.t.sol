// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {isTimeValid, computeStepSize} from "../../src/math/time.sol";
import {LibBit} from "solady/utils/LibBit.sol";

contract TimeTest is Test {
    function test_computeStepSize() public pure {
        assertEq(computeStepSize(0, 4), 16, "0,4");
        assertEq(computeStepSize(4, 0), 16, "4,0");
        assertEq(
            computeStepSize(type(uint256).max - type(uint32).max, type(uint256).max), uint256(1) << 28, "max-u32max,max"
        );
        assertEq(computeStepSize(0, type(uint256).max), uint256(1) << 28, "0,type(uint256).max");
    }

    function test_computeStepSize_invariants(uint256 currentTime, uint256 time) public pure {
        uint256 stepSize = computeStepSize(currentTime, time);
        assertTrue(LibBit.fls(stepSize) % 4 == 0, "step size is a power of 16");

        if (time < currentTime) {
            assertEq(stepSize, 16);
        } else if (time - currentTime < 256) {
            assertEq(stepSize, 16);
        } else if (time - currentTime < 4096) {
            assertEq(stepSize, 256);
        } else if (time - currentTime < 65536) {
            assertEq(stepSize, 4096);
        } else if (time - currentTime < 1048576) {
            assertEq(stepSize, 65536);
        } else if (time - currentTime < 16777216) {
            assertEq(stepSize, 1048576);
        } else if (time - currentTime < 268435456) {
            assertEq(stepSize, 16777216);
        } else {
            assertEq(stepSize, 268435456);
        }
    }

    function test_isTimeValid_past_or_close_time() public pure {
        assertTrue(isTimeValid(0, 16));
        assertTrue(isTimeValid(8, 16));
        assertTrue(isTimeValid(9, 16));
        assertTrue(isTimeValid(15, 16));
        assertTrue(isTimeValid(16, 16));
        assertTrue(isTimeValid(17, 16));
        assertTrue(isTimeValid(12345678, 16));
        assertTrue(isTimeValid(12345678, 32));
        assertTrue(isTimeValid(12345678, 0));
    }

    function test_isTimeValid_future_times_near() public pure {
        assertTrue(isTimeValid(0, 16));
        assertTrue(isTimeValid(8, 16));
        assertTrue(isTimeValid(9, 16));
        assertTrue(isTimeValid(0, 32));
        assertTrue(isTimeValid(31, 32));

        assertTrue(isTimeValid(0, 256));
        assertTrue(isTimeValid(0, 240));
        assertFalse(isTimeValid(0, 272));
        assertTrue(isTimeValid(16, 256));
        assertTrue(isTimeValid(16, 240));
        assertFalse(isTimeValid(16, 272));

        assertTrue(isTimeValid(0, 512));
        assertFalse(isTimeValid(0, 496));
        assertFalse(isTimeValid(0, 528));
        assertTrue(isTimeValid(16, 512));
        assertFalse(isTimeValid(16, 496));
        assertFalse(isTimeValid(16, 528));
    }

    function test_isTimeValid_future_times_near_second_boundary() public pure {
        assertTrue(isTimeValid(0, 4096));
        assertTrue(isTimeValid(0, 3840));
        assertFalse(isTimeValid(0, 4352));
        assertTrue(isTimeValid(16, 4096));
        assertTrue(isTimeValid(16, 3840));
        assertFalse(isTimeValid(16, 4352));

        assertTrue(isTimeValid(256, 4096));
        assertTrue(isTimeValid(256, 3840));
        assertFalse(isTimeValid(256, 4352));
        assertTrue(isTimeValid(257, 4352));
    }

    function test_isTimeValid_too_far_in_future() public pure {
        assertFalse(isTimeValid(0, uint256(type(uint32).max) + 1));
        assertFalse(isTimeValid(0, 8589934592));
        assertFalse(isTimeValid(8589934592 - type(uint32).max - 1, 8589934592));
        assertTrue(isTimeValid(8589934592 - type(uint32).max, 8589934592));
    }

    function test_isTimeValid_invariants(uint256 currentTime, uint256 time) public pure {
        bool valid = isTimeValid(currentTime, time);
        assertEq(
            valid,
            (time < currentTime && time % 16 == 0)
                || (
                    time > currentTime && time % computeStepSize(currentTime, time) == 0
                        && time - currentTime <= type(uint32).max
                )
        );
    }
}
