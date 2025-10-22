// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

// Returns the fee to charge based on the amount, which is the fee (a 0.64 number) times the
// amount, rounded up
function computeFee(uint128 amount, uint64 fee) pure returns (uint128 result) {
    assembly ("memory-safe") {
        result := shr(64, add(mul(amount, fee), 0xffffffffffffffff))
    }
}

error AmountBeforeFeeOverflow();

// Returns the amount before the fee is applied, which is the amount minus the fee, rounded up
function amountBeforeFee(uint128 afterFee, uint64 fee) pure returns (uint128 result) {
    assembly ("memory-safe") {
        let v := shl(64, afterFee)
        let d := sub(0x10000000000000000, fee)
        result := add(iszero(iszero(mod(v, d))), div(v, d))
        if shr(128, result) {
            mstore(0, 0x0d88f526)
            revert(0x1c, 0x04)
        }
    }
}
