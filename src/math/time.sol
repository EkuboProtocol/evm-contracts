// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console} from "forge-std/console.sol";

type Duration is uint32;

error InvalidDuration();

function toDuration(uint256 start, uint256 end) pure returns (Duration duration) {
    unchecked {
        uint256 difference = end - start;
        if (difference == 0 || difference > end || difference > type(uint32).max) {
            revert InvalidDuration();
        }
        duration = Duration.wrap(uint32(difference));
    }
}

function isTimeValid(uint256 currentTime, uint256 time) pure returns (bool) {
    unchecked {
        uint256 stepSize;

        if (time <= currentTime) {
            stepSize = 16;
        } else {
            stepSize = uint256(1) << FixedPointMathLib.max(4, (((LibBit.fls(time - currentTime)) / 4) * 4));
        }

        return time % stepSize == 0;
    }
}
