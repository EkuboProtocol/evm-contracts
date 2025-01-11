// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

error MsbNonZero();

function msb(uint256 x) pure returns (uint8 res) {
    if (x == 0) revert MsbNonZero();

    assembly ("memory-safe") {
        let s := mul(128, eq(lt(x, 0x100000000000000000000000000000000), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(64, eq(lt(x, 0x10000000000000000), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(32, eq(lt(x, 0x100000000), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(16, eq(lt(x, 0x10000), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(8, eq(lt(x, 0x100), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(4, eq(lt(x, 0x10), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(2, eq(lt(x, 0x4), 0))
        x := shr(s, x)
        res := add(s, res)

        s := mul(1, eq(lt(x, 0x2), 0))
        x := shr(s, x)
        res := add(s, res)
    }
}

error LsbNonZero();

function lsb(uint256 x) pure returns (uint8 res) {
    if (x == 0) revert LsbNonZero();

    assembly ("memory-safe") {
        x := and(x, sub(0, x))
    }

    return msb(x);
}
