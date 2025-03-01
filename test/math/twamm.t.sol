// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {calculateSaleRate, calculateNextSqrtRatio} from "../../src/math/twamm.sol";
import {SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";

contract TwammTest is Test {
    function test_calculateSaleRate_examples() public pure {
        assertEq(calculateSaleRate(1000, 5), (1000 << 32) / 5);
    }

    function test_calculateNextSqrtRatio_examples() public pure {
        // token0SaleRate and token1SaleRate are always non-zero.
        // liquidity is zero, price is sqrt_sale_ratio
        SqrtRatio nextSqrtRatio = calculateNextSqrtRatio({
            sqrtRatio: SqrtRatio.wrap(0),
            liquidity: 0,
            token0SaleRate: 1 << 32,
            token1SaleRate: 1 << 32,
            timeElapsed: 1,
            fee: 0
        });
        // sqrtRatio = 1
        assertEq(nextSqrtRatio.toFixed(), (1 << 128));

        // c is zero since sqrtRatio == sqrt_sale_ratio, price is sqrt_sale_ratio
        nextSqrtRatio = calculateNextSqrtRatio({
            sqrtRatio: toSqrtRatio(1 << 128, false),
            liquidity: (1 << 64),
            token0SaleRate: (1 << 32),
            token1SaleRate: (1 << 32),
            timeElapsed: 1,
            fee: 0
        });
        // sqrtRatio = 1
        assertEq(nextSqrtRatio.toFixed(), (1 << 128));

        nextSqrtRatio = calculateNextSqrtRatio({
            sqrtRatio: toSqrtRatio(1 << 128, false),
            liquidity: 10_000 * 1000000000000000000,
            token0SaleRate: 5000 * (1 << 32),
            token1SaleRate: 500 * (1 << 32),
            timeElapsed: 1,
            fee: 0
        });
        // sqrtRatio ~= .99
        assertEq(nextSqrtRatio.toFixed(), 340282366920938463305873545376503282647);

        // very low liquidity
        nextSqrtRatio = calculateNextSqrtRatio({
            sqrtRatio: toSqrtRatio(1 << 128, false),
            liquidity: 10,
            token0SaleRate: 5000 * (1 << 32),
            token1SaleRate: 500 * (1 << 32),
            timeElapsed: 1,
            fee: 0
        });
        // sqrtRatio will be sqrt_sale_ratio
        assertEq(nextSqrtRatio.toFixed(), 107606732706330320687810575726449262521);
    }
}
