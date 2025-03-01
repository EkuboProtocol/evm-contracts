// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    calculateSaleRate,
    calculateNextSqrtRatio,
    calculateC,
    calculateAmountFromSaleRate
} from "../../src/math/twamm.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";

contract TwammTest is Test {
    function test_calculateSaleRate_examples() public pure {
        assertEq(calculateSaleRate(1000, 5), (1000 << 32) / 5);
    }

    function test_calculateAmountFromSaleRate_examples() public pure {
        // 100 per second
        assertEq(calculateAmountFromSaleRate({saleRate: 100 << 32, duration: 3, roundUp: false}), 300);
        assertEq(calculateAmountFromSaleRate({saleRate: 100 << 32, duration: 3, roundUp: true}), 300);

        // 62.5 per second
        assertEq(calculateAmountFromSaleRate({saleRate: 125 << 31, duration: 3, roundUp: false}), 187);
        assertEq(calculateAmountFromSaleRate({saleRate: 125 << 31, duration: 3, roundUp: true}), 188);

        // nearly 0 per second
        assertEq(calculateAmountFromSaleRate({saleRate: 1, duration: 3, roundUp: false}), 0);
        assertEq(calculateAmountFromSaleRate({saleRate: 1, duration: 3, roundUp: true}), 1);

        // nearly 0 per second
        assertEq(calculateAmountFromSaleRate({saleRate: 1, duration: type(uint32).max, roundUp: false}), 0);
        assertEq(calculateAmountFromSaleRate({saleRate: 1, duration: type(uint32).max, roundUp: true}), 1);

        // max sale rate max duration
        assertEq(
            calculateAmountFromSaleRate({saleRate: type(uint112).max, duration: type(uint32).max, roundUp: false}),
            5192296857325901808915867154513919
        );
        assertEq(
            calculateAmountFromSaleRate({saleRate: type(uint112).max, duration: type(uint32).max, roundUp: true}),
            5192296857325901808915867154513920
        );
    }

    function test_calculateC_examples() public pure {
        assertEq(calculateC(1 << 128, 1 << 129), 6148914691236517205);
        assertEq(calculateC(1 << 128, 1 << 127), -6148914691236517205);
        assertEq(calculateC(1 << 128, 1 << 128), 0);

        // large difference
        assertEq(calculateC(MAX_SQRT_RATIO.toFixed(), MIN_SQRT_RATIO.toFixed()), 447090492618910);
        assertEq(calculateC(MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), -447090492618910);

        // small difference, i.e. large denominator relative to numerator
        assertEq(calculateC(MAX_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed() - 1), 0);
        assertEq(calculateC(MIN_SQRT_RATIO.toFixed() + 1, MIN_SQRT_RATIO.toFixed()), 0);
    }

    function test_gas_cost_calculateNextSqrtRatio() public {
        vm.startSnapshotGas("calculateNextSqrtRatio");
        calculateNextSqrtRatio({
            sqrtRatio: toSqrtRatio(10_000 << 128, false),
            liquidity: 10_000,
            token0SaleRate: 458864027,
            token1SaleRate: 280824784,
            timeElapsed: 46_800,
            fee: 0
        });
        vm.stopSnapshotGas();
    }

    function test_calculateNextSqrtRatio_examples() public pure {
        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(10_000 << 128, false),
                liquidity: 10_000,
                token0SaleRate: 458864027,
                token1SaleRate: 280824784,
                timeElapsed: 46_800,
                fee: 0
            }).toFixed(),
            714795237128251225756468394774807707648
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio((uint256(1) << 128) / 10_000, false),
                liquidity: 1_000_000,
                token0SaleRate: 707 << 32,
                token1SaleRate: 179 << 32,
                timeElapsed: 12,
                fee: uint64((uint256(30) << 64) / 10_000)
            }).toFixed(),
            762756935914759524731213789079273472
        );
    }
}
