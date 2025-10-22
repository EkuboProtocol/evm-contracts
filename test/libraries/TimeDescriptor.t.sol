// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";

import {toQuarter, toDate} from "../../src/libraries/TimeDescriptor.sol";

contract TimeDescriptorTest is Test {
    using LibString for *;

    function testToDate() public pure {
        string memory dateLabel = toDate(1756143502);
        assertEq(dateLabel, "Aug/25/2025");

        dateLabel = toDate(1772557200);
        assertEq(dateLabel, "Mar/3/2026");

        dateLabel = toDate(1775016000);
        assertEq(dateLabel, "Apr/1/2026");
    }

    function testToQuarter() public pure {
        string memory quarterLabel = toQuarter(1756143502);
        assertEq(quarterLabel, "25Q3");

        quarterLabel = toQuarter(1772557200);
        assertEq(quarterLabel, "26Q1");

        quarterLabel = toQuarter(1775016000);
        assertEq(quarterLabel, "26Q2");

        quarterLabel = toQuarter(4102506000);
        assertEq(quarterLabel, "00Q1");

        quarterLabel = toQuarter(4110278400);
        assertEq(quarterLabel, "00Q2");

        quarterLabel = toQuarter(4394275200);
        assertEq(quarterLabel, "09Q2");
    }

    function testNeverRevertsFollowsFormat(uint256 unlockTime) public pure {
        string memory quarterLabel = toQuarter(unlockTime);
        string[] memory quarterPieces = LibString.split(quarterLabel, "Q");
        assertEq(quarterPieces.length, 2);

        string memory dateLabel = toDate(unlockTime);
        string[] memory datePieces = LibString.split(dateLabel, "/");
        assertEq(datePieces.length, 3);
    }
}
