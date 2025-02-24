// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";

type Duration is uint32;

error InvalidDuration();

function toDuration(uint256 start, uint256 end) returns (Duration duration) {
    unchecked {
        uint256 difference = end - start;
        if (difference == 0 || difference > end || difference > type(uint32).max) {
            revert InvalidDuration();
        }
        duration = Duration.wrap(uint32(difference));
    }
}

function isTimeValid(uint256 currentTime, uint256 time) returns (bool) {
    unchecked {
        if (time <= currentTime) {
            return (time % 16) == 0;
        } else {
            return (time % (1 << ((LibBit.fls(time - currentTime) + 4) / 4))) == 0;
        }
    }
}
