// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    liquidityDeltaToAmountDelta,
    LiquidityDeltaOverflow,
    addLiquidityDelta,
    subLiquidityDelta,
    maxLiquidity
} from "../../src/math/liquidity.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";

int32 constant TICKS_IN_ONE_PERCENT = 9950;

// contract LiquidityTest is Test {
//     function amountDeltas(uint256 sqrtRatio, int128 liquidityDelta, uint256 sqrtRatioLower, uint256 sqrtRatioUpper)
//         external
//         pure
//         returns (int128 delta0, int128 delta1)
//     {
//         (delta0, delta1) = liquidityDeltaToAmountDelta(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);
//     }

//     function test_liquidityDeltaToAmountDelta_full_range_mid_price() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
//             0x100000000000000000000000000000000, // (1 << 128)
//             10000,
//             MIN_SQRT_RATIO,
//             MAX_SQRT_RATIO
//         );
//         assertEq(amount0, 10000, "amount0");
//         assertEq(amount1, 10000, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_sign(
//         uint256 sqrtRatio,
//         int128 liquidityDelta,
//         uint256 sqrtRatioLower,
//         uint256 sqrtRatioUpper
//     ) public view {
//         sqrtRatio = bound(sqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
//         sqrtRatioLower = bound(sqrtRatioLower, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
//         sqrtRatioUpper = bound(sqrtRatioUpper, MIN_SQRT_RATIO, MAX_SQRT_RATIO);

//         vm.assumeNoRevert();
//         (int128 delta0, int128 delta1) = this.amountDeltas(sqrtRatio, liquidityDelta, sqrtRatioLower, sqrtRatioUpper);

//         if (sqrtRatioLower == sqrtRatioUpper || liquidityDelta == 0) {
//             assertEq(delta0, 0);
//             assertEq(delta1, 0);
//         } else if (liquidityDelta < 0) {
//             assertLe(delta0, 0);
//             assertLe(delta1, 0);
//         } else if (liquidityDelta > 0) {
//             assertTrue(delta1 != 0 || delta0 != 0);
//             assertGe(delta0, 0);
//             assertGe(delta1, 0);
//         }
//     }

//     function test_liquidityDeltaToAmountDelta_full_range_mid_price_withdraw() public pure {
//         (int128 amount0, int128 amount1) =
//             liquidityDeltaToAmountDelta(0x100000000000000000000000000000000, -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
//         assertEq(amount0, -9999, "amount0");
//         assertEq(amount1, -9999, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_low_price_in_range() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
//             79228162514264337593543950336, // (1 << 96)
//             10000,
//             MIN_SQRT_RATIO,
//             MAX_SQRT_RATIO
//         );
//         assertEq(amount0, 42949672960000, "amount0");
//         assertEq(amount1, 1, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_low_price_in_range_withdraw() public pure {
//         (int128 amount0, int128 amount1) =
//             liquidityDeltaToAmountDelta(79228162514264337593543950336, -10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
//         assertEq(amount0, -42949672959999, "amount0");
//         assertEq(amount1, 0, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_high_price_in_range() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(1 << 160, 10000, MIN_SQRT_RATIO, MAX_SQRT_RATIO);
//         assertEq(amount0, 1, "amount0");
//         assertEq(amount1, 42949672960000, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_concentrated_mid_price() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
//             1 << 128,
//             10000,
//             tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100 * -1),
//             tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
//         );
//         assertEq(amount0, 3920, "amount0");
//         assertEq(amount1, 3920, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_low() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
//             1 << 96, 10000, tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100), tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
//         );
//         assertEq(amount0, 10366, "amount0");
//         assertEq(amount1, 0, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_concentrated_out_of_range_high() public pure {
//         (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
//             1 << 160, 10000, tickToSqrtRatio(TICKS_IN_ONE_PERCENT * -100), tickToSqrtRatio(TICKS_IN_ONE_PERCENT * 100)
//         );
//         assertEq(amount0, 0, "amount0");
//         assertEq(amount1, 10366, "amount1");
//     }

//     function test_liquidityDeltaToAmountDelta_concentrated_in_range() public pure {
//         (int128 amount0, int128 amount1) =
//             liquidityDeltaToAmountDelta(tickToSqrtRatio(0), 1000000000, tickToSqrtRatio(-10), tickToSqrtRatio(10));
//         assertEq(amount0, 5000, "amount0");
//         assertEq(amount1, 5000, "amount1");
//     }

//     function test_addLiquidityDelta() public {
//         vm.expectRevert(LiquidityDeltaOverflow.selector);
//         addLiquidityDelta(type(uint128).max, 1);
//         vm.expectRevert(LiquidityDeltaOverflow.selector);
//         addLiquidityDelta(0, -1);
//     }

//     function test_addLiquidityDeltaInvariants(uint128 liquidity, int128 delta) public {
//         int256 result = int256(uint256(liquidity)) + delta;
//         if (result < 0) {
//             vm.expectRevert(LiquidityDeltaOverflow.selector);
//         } else if (result > int256(uint256(type(uint128).max))) {
//             vm.expectRevert(LiquidityDeltaOverflow.selector);
//         }
//         assertEq(int256(uint256(addLiquidityDelta(liquidity, delta))), result);
//     }

//     function test_addLiquidityDelta_examples() public pure {
//         assertEq(addLiquidityDelta(0, 100), 100);
//         assertEq(addLiquidityDelta(0, type(int128).max), uint128(type(int128).max));
//         assertEq(addLiquidityDelta(type(uint128).max, 0), type(uint128).max);
//         assertEq(addLiquidityDelta(type(uint128).max >> 1, 1), uint128(1) << 127);
//         assertEq(addLiquidityDelta(1 << 127, type(int128).min), 0);
//         assertEq(addLiquidityDelta(0, type(int128).max), type(uint128).max >> 1);
//         assertEq(addLiquidityDelta(type(uint128).max, type(int128).min), type(uint128).max >> 1);
//     }

//     function test_subLiquidityDelta() public {
//         vm.expectRevert(LiquidityDeltaOverflow.selector);
//         subLiquidityDelta(type(uint128).max, -1);
//         vm.expectRevert(LiquidityDeltaOverflow.selector);
//         subLiquidityDelta(0, 1);
//     }

//     function test_subLiquidityDeltaInvariants(uint128 liquidity, int128 delta) public {
//         int256 result = int256(uint256(liquidity)) - delta;
//         if (result < 0) {
//             vm.expectRevert(LiquidityDeltaOverflow.selector);
//         } else if (result > int256(uint256(type(uint128).max))) {
//             vm.expectRevert(LiquidityDeltaOverflow.selector);
//         }
//         assertEq(int256(uint256(subLiquidityDelta(liquidity, delta))), result);
//     }

//     function ml(uint256 sqrtRatio, uint256 sqrtRatioA, uint256 sqrtRatioB, uint128 amount0, uint128 amount1)
//         external
//         pure
//         returns (uint128)
//     {
//         return maxLiquidity(sqrtRatio, sqrtRatioA, sqrtRatioB, amount0, amount1);
//     }

//     function test_maxLiquidity(
//         uint256 sqrtRatio,
//         uint256 sqrtRatioLower,
//         uint256 sqrtRatioUpper,
//         uint128 amount0,
//         uint128 amount1
//     ) public view {
//         amount0 = uint128(bound(amount0, 0, type(uint8).max));
//         amount1 = uint128(bound(amount1, 0, type(uint8).max));
//         // creates a minimum separation of .0001%, which causes it to overflow liquidity less often
//         sqrtRatioLower = bound(sqrtRatioLower, MIN_SQRT_RATIO, MAX_SQRT_RATIO - 1);
//         sqrtRatioUpper = bound(sqrtRatioUpper, sqrtRatioLower + 1, MAX_SQRT_RATIO);

//         // this can overflow in some cases
//         vm.assumeNoRevert();
//         uint128 liquidity = this.ml(sqrtRatio, sqrtRatioLower, sqrtRatioUpper, amount0, amount1);

//         if (sqrtRatio <= sqrtRatioLower && amount0 == 0) {
//             assertEq(liquidity, 0);
//         } else if (sqrtRatio >= sqrtRatioUpper && amount1 == 0) {
//             assertEq(liquidity, 0);
//         }

//         // if we were capped at max liquidity, there isn't much we can assert, except maybe that the amount deltas likely overflow
//         if (liquidity <= uint128(type(int128).max)) {
//             (int128 a, int128 b) = this.amountDeltas(sqrtRatio, int128(liquidity), sqrtRatioLower, sqrtRatioUpper);

//             assertGe(a, 0);
//             assertGe(b, 0);
//             assertLe(uint128(a), amount0);
//             assertLe(uint128(b), amount1);
//         }
//     }
// }
