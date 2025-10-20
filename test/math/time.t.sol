// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Test} from "forge-std/Test.sol";
import {isTimeValid, computeStepSize, nextValidTime} from "../../src/math/time.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract TimeTest is Test {
    function test_computeStepSize_boundaries(uint256 time) public pure {
        time = bound(time, 0, type(uint256).max - type(uint32).max);

        unchecked {
            for (uint256 i = 1; i < 8; i++) {
                uint256 expectedStepSize = FixedPointMathLib.max(16, 1 << (i * 4));
                uint256 expectedStepSizePrevious = FixedPointMathLib.max(16, 1 << ((i - 1) * 4));
                assertEq(computeStepSize(time, time + expectedStepSize), expectedStepSize);
                assertEq(computeStepSize(time + 1, time + expectedStepSize), expectedStepSizePrevious);
            }
        }
    }

    function test_computeStepSize() public pure {
        assertEq(computeStepSize(0, 4), 16, "0, 4");
        assertEq(computeStepSize(4, 0), 16, "4, 0");
        assertEq(
            computeStepSize(type(uint256).max - type(uint32).max, type(uint256).max),
            uint256(1) << 28,
            "max-u32max, max"
        );
        assertEq(computeStepSize(0, type(uint256).max), uint256(1) << 252, "0, type(uint256).max");
        assertEq(computeStepSize(7553, 7936), 256, "7553, 7936");
        assertEq(computeStepSize(7553, 8192), 256, "7553, 8192");
        assertEq(computeStepSize(4026531839, 4294967295), uint256(1) << 28, "4026531839, 4294967295");
        assertEq(
            computeStepSize(
                115792089237316195423570985008687907853269984665640564039457584007908834672640,
                115792089237316195423570985008687907853269984665640564039457584007912861204480
            ),
            268435456,
            "big diff large num"
        );
    }

    function test_computeStepSize_invariants(uint256 currentTime, uint256 time) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - 255);
        uint256 stepSize = computeStepSize(currentTime, time);

        if (time < currentTime) {
            assertEq(stepSize, 16);
        } else if (time - currentTime < 256) {
            assertEq(stepSize, 16);
        } else {
            assertEq(stepSize, 1 << ((FixedPointMathLib.log2(time - currentTime) / 4) * 4));
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
        currentTime = bound(currentTime, 0, type(uint256).max - 255);
        assertEq(
            isTimeValid(currentTime, time),
            (time % computeStepSize(currentTime, time) == 0)
                && (time < currentTime || time - currentTime <= type(uint32).max)
        );
    }

    function test_nextValidTime_examples() public pure {
        assertEq(nextValidTime(0, 15), 16);
        assertEq(nextValidTime(0, 16), 32);
        assertEq(nextValidTime(1, 300), 512);
        assertEq(nextValidTime(7847, 7487), 7488);
        assertEq(
            nextValidTime(
                // difference is 4026531840, next valid time does not exist
                115792089237316195423570985008687907853269984665640564039457584007908834672640,
                115792089237316195423570985008687907853269984665640564039457584007912861204480
            ),
            0
        );
        assertEq(nextValidTime(type(uint256).max - type(uint32).max, type(uint256).max), 0);
        assertEq(nextValidTime(1, 855925747424054960923167675474377675291071944039765111602490794982751), 0);
    }

    function test_nextValidTime_invariants(uint256 currentTime, uint256 time) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint32).max);
        uint256 nextValid = nextValidTime(currentTime, time);
        assertTrue(isTimeValid(currentTime, nextValid), "always valid");
        if (time < currentTime) {
            // we just snap to the next multiple of 16
            assertEq(nextValid, ((time / 16) + 1) * 16);
        } else if (nextValid != 0) {
            assertGt(nextValid, time);
            uint256 diff = nextValid - time;
            assertLe(diff, computeStepSize(currentTime, nextValid));
            assertLe(diff, type(uint32).max);
            assertGe(nextValid - currentTime, computeStepSize(currentTime, time) >> 4);
        } else {
            assertGt(time - currentTime, type(uint32).max - 268435456);
        }
    }
}
