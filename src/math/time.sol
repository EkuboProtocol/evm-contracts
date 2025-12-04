// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// For any given time `t`, there are up to 91 times that are greater than `t` and valid according to `isTimeValid`
uint256 constant MAX_NUM_VALID_TIMES = 91;

// If we constrain the sale rate delta to this value, then the current sale rate will never overflow
uint256 constant MAX_ABS_VALUE_SALE_RATE_DELTA = type(uint112).max / MAX_NUM_VALID_TIMES;

/// @dev Returns the step size, i.e. the value of which the order end or start time must be a multiple of, based on the current time and the specified time
///      The step size has a minimum of 256 seconds and increases in powers of 16 as the gap to `time` grows.
///      Assumes currentTime < type(uint256).max - 4095
/// @param currentTime The current block timestamp
/// @param time The time for which the step size is being computed, based on how far in the future it is from currentTime
function computeStepSize(uint256 currentTime, uint256 time) pure returns (uint256 stepSize) {
    assembly ("memory-safe") {
        switch gt(time, add(currentTime, 4095))
        case 1 {
            let diff := sub(time, currentTime)

            let msb := sub(255, clz(diff)) // = index of msb

            msb := sub(msb, mod(msb, 4)) // = round down to multiple of 4

            stepSize := shl(msb, 1)
        }
        default { stepSize := 256 }
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
