// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// For any given time `t`, there are up to 106 times that are greater than `t` and valid according to `isTimeValid`
uint256 constant MAX_NUM_VALID_TIMES = 106;

// If we constrain the sale rate delta to this value, then the current sale rate will never overflow
uint256 constant MAX_ABS_VALUE_SALE_RATE_DELTA = type(uint112).max / MAX_NUM_VALID_TIMES;

/// @dev Returns the step size, i.e. the value of which the order end or start time must be a multiple of, based on the current time and the specified time
///      The step size is equal to 16 ** (max(1, floor(log base 16 of (time - currentTime))))
///      Assumes currentTime < type(uint256).max - 255
function computeStepSize(uint256 currentTime, uint256 time) pure returns (uint256 stepSize) {
    assembly ("memory-safe") {
        switch gt(time, add(currentTime, 255))
        case 1 {
            let diff := sub(time, currentTime)
            let shift := 2

            // add 1 if diff greater than each power of (16**n)-1
            // diff greater than 7th power is not a valid time
            shift := add(shift, gt(diff, sub(shl(12, 1), 1)))
            shift := add(shift, gt(diff, sub(shl(16, 1), 1)))
            shift := add(shift, gt(diff, sub(shl(20, 1), 1)))
            shift := add(shift, gt(diff, sub(shl(24, 1), 1)))
            shift := add(shift, gt(diff, sub(shl(28, 1), 1)))

            stepSize := shl(mul(shift, 4), 1)
        }
        default { stepSize := 16 }
    }
}

/// @dev Returns true iff the given time is a valid start or end time for a TWAMM order
function isTimeValid(uint256 currentTime, uint256 time) pure returns (bool valid) {
    uint256 stepSize = computeStepSize(currentTime, time);

    assembly ("memory-safe") {
        valid := and(iszero(mod(time, stepSize)), or(lt(time, currentTime), lt(sub(time, currentTime), 0x100000000)))
    }
}

/// @dev Returns the next valid time if there is one, or wraps around to the time 0 if there is not
///      Assumes currentTime is less than type(uint256).max - type(uint32).max
function nextValidTime(uint256 currentTime, uint256 time) pure returns (uint256 nextTime) {
    unchecked {
        uint256 stepSize = computeStepSize(currentTime, time);
        assembly ("memory-safe") {
            nextTime := add(time, stepSize)
            nextTime := sub(nextTime, mod(nextTime, stepSize))
        }

        // only if we didn't overflow
        if (nextTime != 0) {
            uint256 nextStepSize = computeStepSize(currentTime, nextTime);
            if (nextStepSize != stepSize) {
                assembly ("memory-safe") {
                    nextTime := add(time, nextStepSize)
                    nextTime := sub(nextTime, mod(nextTime, nextStepSize))
                }
            }
        }

        nextTime = FixedPointMathLib.ternary(nextTime > currentTime + type(uint32).max, 0, nextTime);
    }
}
