// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "../FullTest.sol";
import {TWAMMDataFetcher, getAllValidTimes} from "../../src/lens/TWAMMDataFetcher.sol";
import {isTimeValid} from "../../src/math/time.sol";

contract TWAMMDataFetcherTest is FullTest {
    TWAMMDataFetcher internal tdf;

    function setUp() public override {
        FullTest.setUp();
    }

    function test_getAllValidTimes(uint256 currentTime) public pure {
        currentTime = bound(currentTime, 0, type(uint256).max - type(uint64).max);

        uint256[] memory times = getAllValidTimes(currentTime);

        assertGt(times[0], currentTime);
        assertLe(times[0], currentTime + 16);

        for (uint256 i = 0; i < times.length; i++) {
            if (i != 0) {
                assertGt(times[i], times[i - 1], "ordered");
            }
            assertTrue(isTimeValid(currentTime, times[i]), "valid");
        }

        assertTrue(times.length == 105 || times.length == 106);
    }

    function test_getAllValidTimes_example() public pure {
        uint256[] memory times = getAllValidTimes(1);
        assertEq(times[0], 16);
        assertEq(times[1], 32);
        assertEq(times[14], 240);
        assertEq(times[15], 256);
        assertEq(times[16], 512);
        assertEq(times[29], 3840);
        assertEq(times[30], 4096);
        assertEq(times[31], 8192);
        assertEq(times[44], 61440);
        assertEq(times[45], 65536);
        assertEq(times[46], 131072);
        assertEq(times[times.length - 2], 4026531840);
        assertEq(times[times.length - 1], 4294967296);
    }
}
