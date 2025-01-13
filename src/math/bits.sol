// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error MsbNonZero();

function msb(uint256 x) pure returns (uint8 res) {
    if (x == 0) revert MsbNonZero();

    res = uint8(FixedPointMathLib.log2(x));
}

error LsbNonZero();

function lsb(uint256 x) pure returns (uint8 res) {
    if (x == 0) revert LsbNonZero();

    assembly ("memory-safe") {
        x := and(x, sub(0, x))
    }

    return msb(x);
}
