// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Duration, InvalidDuration, toDuration, isTimeValid} from "../../src/math/time.sol";

contract TimeTest is Test {
    function test_toDuration_valid_start_end(uint256 start, uint256 end) public pure {
        start = bound(start, 0, type(uint256).max - type(uint32).max);
        end = bound(end, start + 1, start + type(uint32).max);

        Duration d = toDuration(start, end);
        assertEq(Duration.unwrap(d), end - start);
    }

    function td(uint256 start, uint256 end) external pure returns (Duration d) {
        d = toDuration(start, end);
    }

    function test_td_fail() public {
        vm.expectRevert(InvalidDuration.selector);
        this.td(0, uint256(type(uint32).max) + 1);

        vm.expectRevert(InvalidDuration.selector);
        this.td(0, 0);

        vm.expectRevert(InvalidDuration.selector);
        this.td(1, 0);

        vm.expectRevert(InvalidDuration.selector);
        this.td(type(uint256).max, 0);

        vm.expectRevert(InvalidDuration.selector);
        this.td(type(uint256).max, type(uint256).max);

        vm.expectRevert(InvalidDuration.selector);
        this.td(type(uint256).max, type(uint256).max - 1);
    }

    function test_toDuration_valid_range(uint256 start, uint256 end) public pure {
        start = bound(start, 0, type(uint256).max - type(uint32).max);
        end = bound(end, start + 1, start + type(uint32).max);

        Duration d = toDuration(start, end);
        assertEq(Duration.unwrap(d), end - start);
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
}
