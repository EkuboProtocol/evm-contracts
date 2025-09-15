// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

function isPriceIncreasing(int128 amount, bool isToken1) pure returns (bool increasing) {
    assembly ("memory-safe") {
        increasing := xor(isToken1, slt(amount, 0))
    }
}
