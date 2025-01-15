// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {isPriceIncreasing, SwapResult, noOpSwapResult, swapResult} from "../../src/math/swap.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/math/ticks.sol";

contract SwapTest is Test {
    function test_isPriceIncreasing() public pure {
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

    function test_swapResult(
        uint256 sqrtRatio,
        uint128 liquidity,
        uint256 sqrtRatioLimit,
        int128 amount,
        bool isToken1,
        uint128 fee
    ) public pure {
        sqrtRatio = bound(sqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
        // this prevents overflow
        liquidity = uint128(bound(liquidity, 1, type(uint112).max));

        uint256 feeMultiplier = type(uint256).max / ((1 << 128) - fee);
        uint256 maxAmount = uint128(type(uint128).max / feeMultiplier);
        amount = int128(bound(amount, -int256(maxAmount), int256(maxAmount)));

        bool increasing = isPriceIncreasing(amount, isToken1);
        if (isPriceIncreasing(amount, isToken1)) {
            sqrtRatioLimit = bound(sqrtRatioLimit, sqrtRatio, MAX_SQRT_RATIO);
        } else {
            sqrtRatioLimit = bound(sqrtRatioLimit, MIN_SQRT_RATIO, sqrtRatio);
        }

        vm.assumeNoRevert();
        SwapResult memory result = swapResult(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);

        if (increasing) {
            assertGe(result.sqrtRatioNext, sqrtRatio);
        } else {
            assertLe(result.sqrtRatioNext, sqrtRatio);
        }
    }
}
