// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {isTimeValid, computeStepSize, nextValidTime, MAX_NUM_VALID_TIMES} from "../../src/math/time.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract TimeTest is Test {
    function test_computeStepSize_boundaries(uint256 currentTime) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint32).max);

        unchecked {
            for (uint256 i = 0; i < 8; i++) {
                uint256 time = currentTime + (1 << (i * 4));
                assertEq(
                    computeStepSize(currentTime, time),
                    FixedPointMathLib.max(256, 1 << (i * 4)),
                    "step size at boundary"
                );
                assertEq(
                    computeStepSize(currentTime + 1, time),
                    FixedPointMathLib.max(256, 1 << ((i - 1) * 4)),
                    "step size if time advanced by 1"
                );
                if (currentTime != 0) {
                    assertEq(
                        computeStepSize(currentTime - 1, time),
                        FixedPointMathLib.max(256, 1 << (i * 4)),
                        "step size if time decreased by 1"
                    );
                }
            }
        }
    }

    function test_MAX_NUM_VALID_TIMES_is_consistent_with_nextValidTime(uint256 time) public {
        time = bound(time, 1, type(uint256).max - type(uint32).max);
        uint256 nextTime = time;
        uint256 numValidTimes;
        while (nextTime != 0) {
            nextTime = nextValidTime(time, nextTime);
            if (nextTime != 0) {
                numValidTimes++;
            }
        }

        assertTrue(numValidTimes == MAX_NUM_VALID_TIMES || numValidTimes == MAX_NUM_VALID_TIMES - 1);
    }

    function test_computeStepSize() public pure {
        assertEq(computeStepSize(0, 4), 256, "0, 4");
        assertEq(computeStepSize(4, 0), 256, "4, 0");
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
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint16).max);
        uint256 stepSize = computeStepSize(currentTime, time);

        if (time < currentTime) {
            assertEq(stepSize, 256, "time lt currentTime");
        } else if (time - currentTime < 4096) {
            assertEq(stepSize, 256, "time is within 4096 of currentTime");
        } else {
            assertEq(stepSize, 1 << ((FixedPointMathLib.log2(time - currentTime) / 4) * 4));
        }
    }

    function test_isTimeValid_past_or_close_time() public pure {
        assertTrue(isTimeValid(0, 256));
        assertTrue(isTimeValid(8, 256));
        assertTrue(isTimeValid(9, 256));
        assertTrue(isTimeValid(15, 256));
        assertTrue(isTimeValid(16, 256));
        assertTrue(isTimeValid(17, 256));
        assertTrue(isTimeValid(255, 256));
        assertTrue(isTimeValid(256, 256));
        assertTrue(isTimeValid(257, 256));
        assertTrue(isTimeValid(12345678, 256));
        assertTrue(isTimeValid(12345678, 512));
        assertTrue(isTimeValid(12345678, 0));
    }

    function test_isTimeValid_future_times_near() public pure {
        assertTrue(isTimeValid(0, 256));
        assertTrue(isTimeValid(8, 256));
        assertTrue(isTimeValid(9, 256));
        assertTrue(isTimeValid(0, 512));
        assertTrue(isTimeValid(31, 512));

        assertTrue(isTimeValid(0, 4096));
        assertTrue(isTimeValid(0, 4096 - 256));
        assertFalse(isTimeValid(0, 4096 + 256));
        assertTrue(isTimeValid(256, 4096));
        assertTrue(isTimeValid(256, 4096 - 256));
        assertFalse(isTimeValid(256, 4096 + 256));

        assertTrue(isTimeValid(0, 131_072));
        assertFalse(isTimeValid(0, 131_072 - 256));
        assertFalse(isTimeValid(0, 131_072 - 152));
        assertTrue(isTimeValid(16, 131_072));
        assertFalse(isTimeValid(16, 131_072 - 256));
        assertFalse(isTimeValid(16, 131_072 - 512));
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
        assertEq(nextValidTime(0, 15), 256);
        assertEq(nextValidTime(0, 16), 256);
        assertEq(nextValidTime(0, 255), 256);
        assertEq(nextValidTime(0, 256), 512);

        assertEq(nextValidTime(1, 300), 512);
        assertEq(nextValidTime(7679, 7679), 7680);
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
            assertEq(nextValid, ((time / 256) + 1) * 256);
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
