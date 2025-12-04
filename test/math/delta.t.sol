// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {amount0Delta, amount1Delta, sortAndConvertToFixedSqrtRatios} from "../../src/math/delta.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SqrtRatio, ONE, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";

contract DeltaTest is Test {
    function check_sortSqrtRatios(SqrtRatio a, SqrtRatio b) public pure {
        vm.assume(a.isValid() && b.isValid());
        (uint256 c, uint256 d) = sortAndConvertToFixedSqrtRatios(a, b);

        if (a < b) {
            assertTrue(a.toFixed() == c);
            assertTrue(b.toFixed() == d);
        } else {
            assertTrue(a.toFixed() == d);
            assertTrue(b.toFixed() == c);
        }
    }

    function test_amount0Delta_examples() public pure {
        assertEq(amount0Delta(ONE, MIN_SQRT_RATIO, 1, false), 18446296994052723739);
        assertEq(amount0Delta(MIN_SQRT_RATIO, ONE, 1, false), 18446296994052723739);

        assertEq(amount0Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount0Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount0Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, true), 0);
        assertEq(amount0Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, true), 0);

        assertEq(amount0Delta(toSqrtRatio(339942424496442021441932674757011200255, false), ONE, 1000000, false), 1000);
        assertEq(
            amount0Delta(toSqrtRatio((1 << 128) + 34028236692093846346337460743176821145, false), ONE, 1e18, true),
            90909090909090910
        );
        assertEq(
            amount0Delta(toSqrtRatio((1 << 128) + 340622989910849312776150758189957120, false), ONE, 1000000, false),
            999
        );
        assertEq(amount0Delta(toSqrtRatio(339942424496442021441932674757011200255, false), ONE, 1000000, true), 1001);
    }

    function a0d(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128)
    {
        return amount0Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function test_amount0Delta_fuzz(uint256 sqrtRatioAFixed, uint256 sqrtRatioBFixed, uint128 liquidity, bool roundUp)
        public
        view
    {
        SqrtRatio sqrtRatioA =
            toSqrtRatio(bound(sqrtRatioAFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioB =
            toSqrtRatio(bound(sqrtRatioAFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        (sqrtRatioAFixed, sqrtRatioBFixed) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

        vm.assumeNoRevert();
        uint128 amount = this.a0d(sqrtRatioA, sqrtRatioB, liquidity, roundUp);

        uint256 amountA = (uint256(liquidity) << 128) / sqrtRatioAFixed;
        uint256 amountB = (uint256(liquidity) << 128) / sqrtRatioBFixed;
        uint256 diff = amountA - amountB;

        // it can only be off by up to 1
        if (diff != 0) assertGe(amount, diff - 1);
        if (diff != type(uint256).max) assertLe(amount, diff + 1);
    }

    function test_amount1Delta_examples() public pure {
        assertEq(amount1Delta(ONE, MAX_SQRT_RATIO, 1, false), 18446296994052723737);
        assertEq(amount1Delta(MAX_SQRT_RATIO, ONE, 1, false), 18446296994052723737);
        assertEq(amount1Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount1Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, false), 0);
        assertEq(amount1Delta(MIN_SQRT_RATIO, MIN_SQRT_RATIO, type(uint128).max, true), 0);
        assertEq(amount1Delta(MAX_SQRT_RATIO, MAX_SQRT_RATIO, type(uint128).max, true), 0);

        assertEq(
            amount1Delta(ONE, toSqrtRatio(309347606291762239512158734028880192232, false), 1000000000000000000, true),
            90909090909090910
        );
        assertEq(amount1Delta(ONE, MAX_SQRT_RATIO, 0xffffffffffffffff, false), 340274119756928397675478831269759003622);
    }

    function a1d(SqrtRatio sqrtRatioA, SqrtRatio sqrtRatioB, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint128)
    {
        return amount1Delta(sqrtRatioA, sqrtRatioB, liquidity, roundUp);
    }

    function test_amount1Delta_fuzz(uint256 sqrtRatioAFixed, uint256 sqrtRatioBFixed, uint128 liquidity, bool roundUp)
        public
        view
    {
        SqrtRatio sqrtRatioA =
            toSqrtRatio(bound(sqrtRatioAFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioB =
            toSqrtRatio(bound(sqrtRatioAFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        (sqrtRatioAFixed, sqrtRatioBFixed) = sortAndConvertToFixedSqrtRatios(sqrtRatioA, sqrtRatioB);

        vm.assumeNoRevert();
        uint128 amount = this.a1d(sqrtRatioA, sqrtRatioB, liquidity, roundUp);

        uint256 amountA = FixedPointMathLib.fullMulDivN(liquidity, sqrtRatioAFixed, 128);
        uint256 amountB = FixedPointMathLib.fullMulDivN(liquidity, sqrtRatioBFixed, 128);
        uint256 diff = amountB - amountA;

        // it can only be off by up to 1
        if (diff != 0) assertGe(amount, diff - 1);
        if (diff != type(uint256).max) assertLe(amount, diff + 1);
    }
}
