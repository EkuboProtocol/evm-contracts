// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

//  If we let:
//    b = floor(log₂(x))
//  then the rule is that x must be divisible by
//    2^( max(4, 4 · floor(b/4)) ).
//  A brief breakdown:
//  1. For x with b < 4 (i.e. 1 ≤ x ≤ 15) we have
//    max(4, 0) = 4, so x must be a multiple of 2⁴ = 16.
//    No nonzero x in [1,15] is a multiple of 16 (0 is a special case; we assume f(0) returns true).
//  2. For b between 4 and 7 (x ∈ [16,255]) we again get alignment 2⁴ = 16. But now the intervals split into:
//    • [16,31] gives 1 multiple (16),
//    • [32,63] gives 2 multiples,
//    • [64,127] gives 4 multiples,
//    • [128,255] gives 8 multiples.
//    That’s 1+2+4+8 = 15 valid numbers.
//  3. For b in [8,11] (x ∈ [256,4095]), the alignment becomes 2⁸ = 256 and the four subranges yield counts 1, 2, 4, and 8 (again 15 total).
//  4. This pattern continues for b in [12,15] (alignment 2¹²), [16,19] (alignment 2¹⁶), [20,23] (alignment 2²⁰), [24,27] (alignment 2²⁴), and [28,31] (alignment 2²⁸). Each of these seven groups contributes 15 numbers.
//  Thus the overall valid count is:
//    1 (for x = 0) + 7×15 = 1 + 105 = **106**.
//  So there are up to 106 valid integers in the range of times [t + 0, t + 2³² – 1].
uint256 constant MAX_NUM_VALID_TIMES = 106;

// If we constrain the sale rate delta to this value, then the current sale rate will never overflow
uint256 constant MAX_ABS_VALUE_SALE_RATE_DELTA = type(uint112).max / MAX_NUM_VALID_TIMES;

/// @dev Returns the step size, i.e. the value of which the order end or start time must be a multiple of, based on the current time and the specified time
///      The step size is equal to 16 ** (max(1, floor(log base 16 of (time - currentTime))))
function computeStepSize(uint256 currentTime, uint256 time) pure returns (uint256 stepSize) {
    assembly ("memory-safe") {
        switch gt(time, currentTime)
        case 1 {
            let diff := sub(time, currentTime)
            let shift := 1

            // add 1 if diff greater than each power of (16**n)-1
            // diff greater than 7th power is not a valid time
            shift := add(shift, gt(diff, 255))
            shift := add(shift, gt(diff, 4095))
            shift := add(shift, gt(diff, 65535))
            shift := add(shift, gt(diff, 1048576))
            shift := add(shift, gt(diff, 16777216))
            shift := add(shift, gt(diff, 268435456))

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
