// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {isPriceIncreasing, SwapResult, noOpSwapResult, swapResult} from "../../src/math/swap.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/ticks.sol";

contract SwapTest is Test {
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

    function test_noOpSwapResult(uint256 sqrtRatio) public pure {
        SwapResult memory result = noOpSwapResult(sqrtRatio);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.consumedAmount, 0);
        assertEq(result.feeAmount, 0);
        assertEq(result.sqrtRatioNext, sqrtRatio);
    }

    function sr(uint256 sqrtRatio, uint128 liquidity, uint256 sqrtRatioLimit, int128 amount, bool isToken1, uint128 fee)
        external
        pure
        returns (SwapResult memory)
    {
        return swapResult(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);
    }

    function test_swapResult(
        uint256 sqrtRatio,
        uint128 liquidity,
        uint256 sqrtRatioLimit,
        int128 amount,
        bool isToken1,
        uint128 fee
    ) public view {
        bool increasing = isPriceIncreasing(amount, isToken1);

        vm.assumeNoRevert();
        SwapResult memory result = this.sr(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);

        bool consumedAll = amount == result.consumedAmount;

        if (amount == 0) {
            assertEq(result.sqrtRatioNext, sqrtRatio);
        } else if (increasing) {
            assertGe(result.sqrtRatioNext, sqrtRatio);
            assertLe(result.sqrtRatioNext, sqrtRatioLimit);

            if (consumedAll) {
                assertLe(result.sqrtRatioNext, sqrtRatioLimit);
            } else {
                assertEq(result.sqrtRatioNext, sqrtRatioLimit);
            }
        } else {
            assertLe(result.sqrtRatioNext, sqrtRatio);
            assertGe(result.sqrtRatioNext, sqrtRatioLimit);

            if (consumedAll) {
                assertGe(result.sqrtRatioNext, sqrtRatioLimit);
            } else {
                assertEq(result.sqrtRatioNext, sqrtRatioLimit);
            }
        }

        if (amount > 0) {
            assertLe(result.feeAmount, uint128(amount));
            assertLe(result.consumedAmount, amount);
        } else {
            // we may have only received -50 if we wanted -100
            assertGe(result.consumedAmount, amount);
        }
    }
}
