// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {nextSqrtRatioFromAmount0, nextSqrtRatioFromAmount1} from "../../src/math/sqrtRatio.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, ONE, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract SqrtRatioTest is Test {
    // wrapper for the purpose of vm.assumeNoRevert
    function nsrfa0(SqrtRatio sqrtRatio, uint128 liquidity, int128 amount)
        external
        pure
        returns (SqrtRatio sqrtRatioNext)
    {
        return nextSqrtRatioFromAmount0(sqrtRatio, liquidity, amount);
    }

    // wrapper for the purpose of vm.assumeNoRevert
    function nsrfa1(SqrtRatio sqrtRatio, uint128 liquidity, int128 amount)
        external
        pure
        returns (SqrtRatio sqrtRatioNext)
    {
        return nextSqrtRatioFromAmount1(sqrtRatio, liquidity, amount);
    }

    function a0d(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128 amount0)
    {
        amount0 = amount0Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function a1d(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128 amount1)
    {
        amount1 = amount1Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function assertSqrtRatioEq(SqrtRatio a, SqrtRatio b) private pure {
        assertEq(SqrtRatio.unwrap(a), SqrtRatio.unwrap(b), "sqrtRatioEq");
    }

    function test_nextSqrtRatioFromAmount0() public pure {
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount0(ONE, 1 << 96, 10000), toSqrtRatio(340282366920938463463374564482095251457, true)
        );
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount0(ONE, 1 << 96, -10000), toSqrtRatio(340282366920938463463374650381441171457, true)
        );
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount0(ONE, 1000000, 1000), toSqrtRatio(339942424496442021441932674757011200256, true)
        );
        assertSqrtRatioEq(nextSqrtRatioFromAmount0(ONE, 1, -100000000000000), SqrtRatio.wrap(type(uint128).max));
        assertSqrtRatioEq(nextSqrtRatioFromAmount0(MIN_SQRT_RATIO, 1, type(int128).max), toSqrtRatio(2, true));
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount0(ONE, 100000000000, -1000),
            toSqrtRatio((1 << 128) + 3402823703237621667009962744418, true)
        );
    }

    function test_exampleFailure() public view {
        SqrtRatio sqrtRatio = SqrtRatio.wrap(170141183460469231752067778737020830138);
        uint128 liquidity = 1193162642746963740395886491286;
        int128 amount = -45721516157224221702990211;
        SqrtRatio sqrtRatioNext = this.nsrfa0(sqrtRatio, liquidity, amount);
        uint128 delta = this.a0d(sqrtRatio, sqrtRatioNext, liquidity, false);
        assertLe(uint128(-amount), delta);
    }

    function test_nextSqrtRatioFromAmount0_compared_amount0Delta(
        uint256 sqrtRatioFixed,
        uint128 liquidity,
        int128 amount
    ) public view {
        vm.assumeNoRevert();
        sqrtRatioFixed = bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());
        SqrtRatio sqrtRatio = toSqrtRatio(sqrtRatioFixed, false);
        sqrtRatioFixed = sqrtRatio.toFixed();

        SqrtRatio sqrtRatioNext = this.nsrfa0(sqrtRatio, liquidity, amount);

        unchecked {
            // this assertion ensures that the next sqrt ratio we compute is either sufficient to produce the requested amount0,
            // or more than the amount required to move to that price
            if (amount < 0) {
                assertGt(sqrtRatioNext.toFixed(), sqrtRatioFixed, "next price increasing");
                if (SqrtRatio.unwrap(sqrtRatioNext) == type(uint128).max) {
                    // if we overflowed, the amount in the pool is not enough to support the trade
                    assertLe(
                        (uint256(liquidity) << 128) / sqrtRatioFixed,
                        uint128(-amount),
                        "the amount available for current liquidity is too low"
                    );
                } else {
                    vm.assumeNoRevert();
                    assertLe(
                        uint128(-amount),
                        this.a0d(sqrtRatio, sqrtRatioNext, liquidity, false),
                        "amount taken out is less than the delta"
                    );
                }
            } else if (amount > 0) {
                assertLe(SqrtRatio.unwrap(sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio), "sqrt ratio decreased");
                assertGe(
                    uint128(amount), this.a0d(sqrtRatio, sqrtRatioNext, liquidity, true), "the amount is g.e. the delta"
                );
            } else {
                assertEq(SqrtRatio.unwrap(sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio), "price did not move");
                assertEq(amount, 0, "amount is 0");
            }
        }
    }

    function test_nextSqrtRatioFromAmount1() public pure {
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount1(ONE, 1000000, 1000),
            toSqrtRatio((1 << 128) + 340282366920938463463374607431768211, false)
        );
        assertSqrtRatioEq(
            nextSqrtRatioFromAmount1(ONE, 1000000, -1000), toSqrtRatio(339942084554017524999911232824336443244, false)
        );
        assertSqrtRatioEq(nextSqrtRatioFromAmount1(ONE, 1, -1000000), SqrtRatio.wrap(0));
        // 0 in case of overflow
        assertEq(
            SqrtRatio.unwrap(nextSqrtRatioFromAmount1(SqrtRatio.wrap(type(uint128).max - 1), 1, type(int128).max)),
            type(uint128).max,
            "overflow from amount1 in"
        );
    }

    function test_nextSqrtRatioFromAmount1_compared_amount1Delta(
        uint256 sqrtRatioFixed,
        uint128 liquidity,
        int128 amount
    ) public view {
        vm.assumeNoRevert();
        sqrtRatioFixed = bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed());

        SqrtRatio sqrtRatio = toSqrtRatio(sqrtRatioFixed, false);
        sqrtRatioFixed = sqrtRatio.toFixed();

        SqrtRatio sqrtRatioNext = this.nsrfa1(sqrtRatio, liquidity, amount);

        // this assertion ensures that the next sqrt ratio we compute is either sufficient to produce the requested amount0,
        // or more than the amount required to move to that price
        unchecked {
            if (amount < 0) {
                assertLt(SqrtRatio.unwrap(sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio));
                // if we overflowed, the amount in the pool is not enough to support the trade
                if (SqrtRatio.unwrap(sqrtRatioNext) == 0) {
                    assertLe(
                        FixedPointMathLib.fullMulDivN(sqrtRatioFixed, liquidity, 128),
                        uint128(-amount),
                        "insufficient amount available"
                    );
                } else {
                    vm.assumeNoRevert();
                    assertLe(
                        uint128(-amount),
                        this.a1d(sqrtRatio, sqrtRatioNext, liquidity, false),
                        "amount taken out is less than the delta"
                    );
                }
            } else if (amount > 0) {
                assertGe(SqrtRatio.unwrap(sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio), "ratio increases for token1 > 0");
                assertGe(
                    uint128(amount),
                    this.a1d(sqrtRatio, sqrtRatioNext, liquidity, true),
                    "sqrt ratio increase is rounded down"
                );
            } else {
                assertSqrtRatioEq(sqrtRatioNext, sqrtRatio);
                assertEq(amount, 0);
            }
        }
    }
}
