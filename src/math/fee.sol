// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// Returns the fee to charge based on the amount, which is the fee (a 0.128 number) times the
// amount, rounded up
function computeFee(uint128 amount, uint64 fee) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := shr(64, add(mul(amount, fee), 0xffffffffffffffff))
    }
}

error AmountBeforeFeeOverflow();

// Returns the amount before the fee is applied, which is the amount minus the fee, rounded up
function amountBeforeFee(uint128 afterFee, uint64 fee) pure returns (uint128 result) {
    uint256 r;
    assembly ("memory-safe") {
        let v := shl(64, afterFee)
        let d := sub(0x10000000000000000, fee)
        let q := div(v, d)
        r := add(iszero(iszero(mod(v, d))), q)
    }
    if (r > type(uint128).max) {
        revert AmountBeforeFeeOverflow();
    }
    result = uint128(r);
}
