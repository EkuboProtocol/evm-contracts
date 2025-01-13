// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "../../src/math/sqrtRatio.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/ticks.sol";
import {amount0Delta} from "../../src/math/delta.sol";

contract SqrtRatioTest is Test {
    function test_nextSqrtRatioFromAmount0() public pure {
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1 << 96, 10000), 340282366920938463463374564482095251457);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1 << 96, -10000), 340282366920938463463374650381441171457);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1000000, 1000), 339942424496442021441932674757011200256);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1, -100000000000000), 0);
        assertEq(nextSqrtRatioFromAmount0(MIN_SQRT_RATIO, 1, type(int128).max), 2);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 100000000000, -1000), (1 << 128) + 3402823703237621667009962744418);
    }

    function test_nextSqrtRatioFromAmount0_compared_amount0Delta(uint256 sqrtRatio, uint128 liquidity, int128 amount)
        public
        pure
    {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        sqrtRatio = bound(sqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO);

        uint256 sqrtRatioNext = nextSqrtRatioFromAmount0(sqrtRatio, liquidity, amount);
        // this assertion ensures that the next sqrt ratio we compute is either sufficient to produce the requested amount0,
        // or more than the amount required to move to that price
        if (sqrtRatioNext != 0) {
            if (amount < 0) {
                assertLe(uint128(uint256(-int256(amount))), amount0Delta(sqrtRatio, sqrtRatioNext, liquidity, false));
            } else {
                assertGe(uint128(amount), amount0Delta(sqrtRatio, sqrtRatioNext, liquidity, true));
            }
        }
    }

    function test_nextSqrtRatioFromAmount1() public pure {
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1000000, 1000), (1 << 128) + 340282366920938463463374607431768211);
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1000000, -1000), 339942084554017524999911232824336443244);
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1, -1000000), 0);
        // 0 in case of overflow
        assertEq(nextSqrtRatioFromAmount1(type(uint256).max - type(uint128).max, 1, type(int128).max), 0);
    }
}
