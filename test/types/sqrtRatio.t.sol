// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";

contract FeesPerLiquidityTest is Test {
    function test_toFixed_toSqrtRatio(SqrtRatio sqrtRatio) public pure {
        // whether you round up or down, it doesnt matter, since it started as a sqrt ratio
        assertEq(SqrtRatio.unwrap(toSqrtRatio(sqrtRatio.toFixed(), false)), SqrtRatio.unwrap(sqrtRatio));
        assertEq(SqrtRatio.unwrap(toSqrtRatio(sqrtRatio.toFixed(), true)), SqrtRatio.unwrap(sqrtRatio));
    }

    function test_toSqrtRatio_examples() public pure {
        assertEq(SqrtRatio.unwrap(toSqrtRatio(1 << 128, false)), (1 << 127) + (1 << 63));
        assertEq(SqrtRatio.unwrap(toSqrtRatio(1 << 128, true)), (1 << 127) + (1 << 63));

        assertEq(SqrtRatio.unwrap(toSqrtRatio(type(uint128).max, false)), type(uint128).max >> 1);
        assertEq(SqrtRatio.unwrap(toSqrtRatio(type(uint128).max, true)), (1 << 127) + (1 << 63));
    }
}
