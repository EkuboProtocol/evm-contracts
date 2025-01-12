// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Returns the fee to charge based on the amount, which is the fee (a 0.128 number) times the
// amount, rounded up
function computeFee(uint128 amount, uint128 fee) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := shr(128, add(mul(amount, fee), 0xffffffffffffffffffffffffffffffff))
    }
}

error AmountBeforeFeeOverflow();

// Returns the amount before the fee is applied, which is the amount minus the fee, rounded up
function amountBeforeFee(uint128 afterFee, uint128 fee) pure returns (uint128 result) {
    uint256 r;
    assembly ("memory-safe") {
        let v := shl(128, afterFee)
        let d := sub(0x100000000000000000000000000000000, fee)
        let q := div(v, d)
        r := add(iszero(iszero(mod(v, d))), q)
    }
    if (r > type(uint128).max) {
        revert AmountBeforeFeeOverflow();
    }
    result = uint128(r);
}

// Adds two uint128 values, maxing out at the max uint128 value
function accumulateFeeAmount(uint128 a, uint128 b) pure returns (uint128) {
    unchecked {
        return uint128(FixedPointMathLib.min(0xffffffffffffffffffffffffffffffff, uint256(a) + uint256(b)));
    }
}
