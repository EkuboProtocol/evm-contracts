// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "../../src/math/sqrtRatio.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/ticks.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console} from "forge-std/console.sol";

contract SqrtRatioTest is Test {
    // wrapper for the purpose of vm.assumeNoRevert
    function nsrfa0(uint256 sqrtRatio, uint128 liquidity, int128 amount)
        external
        pure
        returns (uint256 sqrtRatioNext)
    {
        return nextSqrtRatioFromAmount0(sqrtRatio, liquidity, amount);
    }

    // wrapper for the purpose of vm.assumeNoRevert
    function nsrfa1(uint256 sqrtRatio, uint128 liquidity, int128 amount)
        external
        pure
        returns (uint256 sqrtRatioNext)
    {
        return nextSqrtRatioFromAmount1(sqrtRatio, liquidity, amount);
    }

    function a0d(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128 amount0)
    {
        amount0 = amount0Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function a1d(uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128 amount1)
    {
        amount1 = amount1Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function test_nextSqrtRatioFromAmount0_compared_amount0Delta_example() public view {
        uint256 sr = 751906813631078839437794237784124293120;
        uint128 liquidity = 1193162642746963740395886491286;
        int128 amount = -45721516157224221702990211;

        uint256 srNext = this.nsrfa0(sr, liquidity, amount);

        assertEq(srNext, 751970485316555610917974631749843097544);

        uint128 delta = this.a0d(sr, srNext, liquidity, false);
        assertEq(delta, 45721516157224221702990211);
    }

    function test_nextSqrtRatioFromAmount0() public pure {
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1 << 96, 10000), 340282366920938463463374564482095251457);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1 << 96, -10000), 340282366920938463463374650381441171457);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1000000, 1000), 339942424496442021441932674757011200256);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 1, -100000000000000), type(uint256).max);
        assertEq(nextSqrtRatioFromAmount0(MIN_SQRT_RATIO, 1, type(int128).max), 2);
        assertEq(nextSqrtRatioFromAmount0(1 << 128, 100000000000, -1000), (1 << 128) + 3402823703237621667009962744418);
    }

    function test_nextSqrtRatioFromAmount0_compared_amount0Delta(uint256 sqrtRatio, uint128 liquidity, int128 amount)
        public
        view
    {
        vm.assumeNoRevert();
        sqrtRatio = bound(sqrtRatio, 1, type(uint256).max - 1);

        uint256 sqrtRatioNext = this.nsrfa0(sqrtRatio, liquidity, amount);

        unchecked {
            // this assertion ensures that the next sqrt ratio we compute is either sufficient to produce the requested amount0,
            // or more than the amount required to move to that price
            if (amount < 0) {
                assertGt(sqrtRatioNext, sqrtRatio);
                if (sqrtRatioNext == type(uint256).max) {
                    // if we overflowed, the amount in the pool is not enough to support the trade
                    assertLe((uint256(liquidity) << 128) / sqrtRatio, uint128(-amount));
                } else {
                    vm.assumeNoRevert();
                    assertLe(uint128(-amount), this.a0d(sqrtRatio, sqrtRatioNext, liquidity, false));
                }
            } else if (amount > 0) {
                assertLe(sqrtRatioNext, sqrtRatio);
                assertGe(uint128(amount), this.a0d(sqrtRatio, sqrtRatioNext, liquidity, true));
            } else {
                assertEq(sqrtRatioNext, sqrtRatio);
                assertEq(amount, 0);
            }
        }
    }

    function test_nextSqrtRatioFromAmount1() public pure {
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1000000, 1000), (1 << 128) + 340282366920938463463374607431768211);
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1000000, -1000), 339942084554017524999911232824336443244);
        assertEq(nextSqrtRatioFromAmount1(1 << 128, 1, -1000000), 0);
        // 0 in case of overflow
        assertEq(
            nextSqrtRatioFromAmount1(type(uint256).max - type(uint128).max, 1, type(int128).max), type(uint256).max
        );
    }

    function test_nextSqrtRatioFromAmount1_compared_amount1Delta(uint256 sqrtRatio, uint128 liquidity, int128 amount)
        public
        view
    {
        vm.assumeNoRevert();
        sqrtRatio = bound(sqrtRatio, 1, type(uint256).max - 1);

        uint256 sqrtRatioNext = this.nsrfa1(sqrtRatio, liquidity, amount);

        // this assertion ensures that the next sqrt ratio we compute is either sufficient to produce the requested amount0,
        // or more than the amount required to move to that price
        unchecked {
            if (amount < 0) {
                assertLt(sqrtRatioNext, sqrtRatio);
                // if we overflowed, the amount in the pool is not enough to support the trade
                if (sqrtRatioNext == 0) {
                    assertLe(FixedPointMathLib.fullMulDivN(sqrtRatio, liquidity, 128), uint128(-amount));
                } else {
                    vm.assumeNoRevert();
                    assertLe(uint128(uint256(-int256(amount))), this.a1d(sqrtRatio, sqrtRatioNext, liquidity, false));
                }
            } else if (amount > 0) {
                assertGe(sqrtRatioNext, sqrtRatio);
                assertGe(uint128(amount), this.a1d(sqrtRatio, sqrtRatioNext, liquidity, true));
            } else {
                assertEq(sqrtRatioNext, sqrtRatio);
                assertEq(amount, 0);
            }
        }
    }
}
