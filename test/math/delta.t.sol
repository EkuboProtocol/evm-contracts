// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    amount0Delta,
    amount1Delta,
    ZeroSqrtRatio,
    Amount0DeltaOverflow,
    Amount1DeltaOverflow
} from "../../src/math/delta.sol";

import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/ticks.sol";

contract DeltaTest is Test {
    function test_amount0Delta() public pure {
        assertEq(amount0Delta(1 << 128, MIN_SQRT_RATIO, 1, false), 18446739710271796308);
        assertEq(amount0Delta(MIN_SQRT_RATIO, 1 << 128, 1, false), 18446739710271796308);
        assertEq(amount0Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount0Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, false), 0);
    }

    function test_amount1Delta() public pure {
        assertEq(amount1Delta(1 << 128, MAX_SQRT_RATIO, 1, false), 18446739710271796308);
        assertEq(amount1Delta(MAX_SQRT_RATIO, 1 << 128, 1, false), 18446739710271796308);
        assertEq(amount1Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount1Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, false), 0);
    }
}
