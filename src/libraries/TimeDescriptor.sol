// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibString} from "solady/utils/LibString.sol";

error UnrecognizedMonth();

// Returns the 3-letter month abbreviation for a given month number (1-12)
function getMonthAbbreviation(uint256 month) pure returns (string memory) {
    if (month == 1) return "Jan";
    if (month == 2) return "Feb";
    if (month == 3) return "Mar";
    if (month == 4) return "Apr";
    if (month == 5) return "May";
    if (month == 6) return "Jun";
    if (month == 7) return "Jul";
    if (month == 8) return "Aug";
    if (month == 9) return "Sep";
    if (month == 10) return "Oct";
    if (month == 11) return "Nov";
    if (month == 12) return "Dec";
    revert UnrecognizedMonth();
}

function toQuarter(uint256 unlockTime) pure returns (string memory quarterLabel) {
    (uint256 year, uint256 month,) = DateTimeLib.timestampToDate(unlockTime);
    year = year % 100;
    string memory shortenedYearStr = LibString.toString(year);

    unchecked {
        quarterLabel =
            string.concat(year < 10 ? "0" : "", shortenedYearStr, "Q", LibString.toString(1 + (month - 1) / 3));
    }
}

function toDate(uint256 unlockTime) pure returns (string memory dateLabel) {
    (uint256 year, uint256 month, uint256 day) = DateTimeLib.timestampToDate(unlockTime);
    string memory yearStr = LibString.toString(year);
    string memory monthStr = getMonthAbbreviation(month);
    string memory dayStr = LibString.toString(day);

    dateLabel = string.concat(monthStr, "/", dayStr, "/", yearStr);
}
