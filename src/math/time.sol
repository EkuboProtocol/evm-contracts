// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console} from "forge-std/console.sol";

function isTimeValid(uint256 currentTime, uint256 time) pure returns (bool) {
    unchecked {
        uint256 stepSize;

        if (time <= currentTime) {
            stepSize = 16;
        } else {
            // cannot be too far in the future
            if (time - currentTime > type(uint32).max) {
                return false;
            }
            stepSize = uint256(1) << FixedPointMathLib.max(4, (((LibBit.fls(time - currentTime)) / 4) * 4));
        }

        return time % stepSize == 0;
    }
}
