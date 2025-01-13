// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error ZeroLiquidityNextSqrtRatioFromAmount0();

// Compute the next ratio from a delta amount0, always rounded towards starting price for input, and
// away from starting price for output
function nextSqrtRatioFromAmount0(uint256 sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (uint256 sqrtRatioNext)
{
    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount0();
    }

    unchecked {
        uint256 liquidityX128 = uint256(liquidity) << 128;
        uint256 amountAbs = FixedPointMathLib.abs(int256(amount));

        // If amountAbs > type(uint256).max / sqrtRatio => overflow in multiplication
        // sqrtRatio is never zero
        // We know if this overflows, the denominator computed below will also always overflow
        if (amountAbs > type(uint256).max / sqrtRatio) {
            // Overflow => return 0
            return 0;
        }

        uint256 product = amountAbs * sqrtRatio;

        // If amount < 0 => price is going up => denominator = (liquidityX128 - product)
        // If amount > 0 => price is going down => denominator = (liquidityX128 + product)
        if (amount < 0) {
            // “Removing token0” => denominator = liquidityX128 - product
            // Check underflow or zero denominator
            // If product >= liquidityX128 => underflow (or denominator=0)
            if (product >= liquidityX128) {
                return 0; // none
            }
            uint256 denominator = liquidityX128 - product;

            sqrtRatioNext = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);
        } else {
            uint256 denominator = liquidityX128 + product;
            // If denominator addition overflowed...
            if (denominator < liquidityX128) {
                return 0;
            }

            sqrtRatioNext = FixedPointMathLib.fullMulDivUp(liquidityX128, sqrtRatio, denominator);
        }
    }

    return sqrtRatioNext;
}

error ZeroLiquidityNextSqrtRatioFromAmount1();

function nextSqrtRatioFromAmount1(uint256 sqrtRatio, uint128 liquidity, int128 amount)
    pure
    returns (uint256 sqrtRatioNext)
{
    if (amount == 0) {
        return sqrtRatio;
    }

    if (liquidity == 0) {
        revert ZeroLiquidityNextSqrtRatioFromAmount1();
    }
}
// // Compute the next ratio from a delta amount1, always rounded towards starting price for input, and
// // away from starting price for output An empty option is returned on overflow/underflow which means
// // the price exceeded the u256 bounds
// pub fn next_sqrt_ratio_from_amount1(
//     sqrt_ratio: u256, liquidity: u128, amount: i129,
// ) -> Option<u256> {
//     if (amount.is_zero()) {
//         return Option::Some(sqrt_ratio);
//     }

//     assert(liquidity.is_non_zero(), 'NO_LIQUIDITY');

//     let (quotient, remainder) = DivRem::div_rem(
//         u256 { low: 0, high: amount.mag }, u256 { low: liquidity, high: 0 }.try_into().unwrap(),
//     );

//     // because quotient is rounded down, this price movement is also rounded towards sqrt_ratio
//     if (amount.sign) {
//         // adding amount1, taking out amount0
//         let (res, overflow) = OverflowingSub::overflowing_sub(sqrt_ratio, quotient);
//         if (overflow) {
//             return Option::None(());
//         }

//         return if (remainder.is_zero()) {
//             Option::Some(res)
//         } else {
//             if (res.is_non_zero()) {
//                 Option::Some(res - 1_u256)
//             } else {
//                 Option::None(())
//             }
//         };
//     } else {
//         // adding amount1, taking out amount0, price goes up
//         let (res, overflow) = OverflowingAdd::overflowing_add(sqrt_ratio, quotient);
//         if (overflow) {
//             return Option::None(());
//         }
//         return Option::Some(res);
//     }
// }
