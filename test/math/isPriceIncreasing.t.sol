// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {isPriceIncreasing} from "../../src/math/isPriceIncreasing.sol";

contract IsPriceIncreasingTest is Test {
    function test_isPriceIncreasing() public pure {
        // zero is assumed to be exact input
        assertFalse(isPriceIncreasing(0, false));
        assertTrue(isPriceIncreasing(0, true));

        // token1 in, token0 out
        assertTrue(isPriceIncreasing(1, true));
        assertTrue(isPriceIncreasing(-1, false));
        // token1 out, token0 in
        assertFalse(isPriceIncreasing(1, false));
        assertFalse(isPriceIncreasing(-1, true));
    }
}
