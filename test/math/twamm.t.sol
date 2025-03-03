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
            saleRateToken0: 458864027,
            saleRateToken1: 280824784,
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
                saleRateToken0: 458864027,
                saleRateToken1: 280824784,
                timeElapsed: 46_800,
                fee: 0
            }).toFixed(),
            714795237151155238153964311638230171648 // 2.1005944081
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio((uint256(1) << 128) / 10_000, false),
                liquidity: 1_000_000,
                saleRateToken0: 707 << 32,
                saleRateToken1: 179 << 32,
                timeElapsed: 12,
                fee: uint64((uint256(30) << 64) / 10_000)
            }).toFixed(),
            762756935888947508383216320167018496 // 0.0022415412
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 100_000 << 32,
                saleRateToken1: 1 << 32,
                timeElapsed: 12,
                fee: 1 << 63
            }).toFixed(),
            212677851090737003826538964680546713600 // 0.6250040312
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 100_000 << 32,
                saleRateToken1: 1 << 32,
                timeElapsed: 12,
                fee: 0
            }).toFixed(),
            154676064193352917687218418238521081856 // 0.4545520992
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 1 << 32,
                saleRateToken1: 100_000 << 32,
                timeElapsed: 12,
                fee: 1 << 63
            }).toFixed(),
            544448275377366823995421509933439385600 // 1.5999896801
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 1 << 32,
                saleRateToken1: 100_000 << 32,
                timeElapsed: 12,
                fee: 0
            }).toFixed(),
            748610263916272246764287404709823643648 // 2.1999678405
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(286363514177267035440548892163466107483369185, false),
                liquidity: 130385243018985227,
                saleRateToken0: 1917585044284,
                saleRateToken1: 893194653345642013054241177,
                timeElapsed: 360,
                fee: 922337203685477580
            }).toFixed(),
            286548851173856260816719751938951829696544768 // 842,091.3894737111
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(1 << 128, false),
                liquidity: 10,
                saleRateToken0: 5000 << 32,
                saleRateToken1: 500 << 32,
                timeElapsed: 1,
                fee: 0
            }).toFixed(),
            107606732706330320687810575739503247360 // ~= 0.316227766
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(286363514177267035440548892163466107483369185, false),
                liquidity: 130385243018985227,
                saleRateToken0: 1917585044284,
                saleRateToken1: 893194653345642013054241177,
                timeElapsed: 360,
                fee: 922337203685477580
            }).toFixed(),
            286548851173856260816719751938951829696544768 // 842,091.3894737111
        );

        assertEq(
            calculateNextSqrtRatio({
                sqrtRatio: toSqrtRatio(1 << 128, false),
                liquidity: 10,
                saleRateToken0: 5000 << 32,
                saleRateToken1: 500 << 32,
                timeElapsed: 1,
                fee: 0
            }).toFixed(),
            107606732706330320687810575739503247360 // ~= 0.316227766
        );
    }

    function test_calculateNextSqrtRatio_always_within_bounds(
        uint256 sqrtRatioFixed,
        uint128 liquidity,
        uint112 saleRateToken0,
        uint112 saleRateToken1,
        uint32 timeElapsed,
        uint64 fee
    ) public pure {
        // valid starting sqrt ratio
        SqrtRatio sqrtRatio =
            toSqrtRatio(bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);

        // if either is 0, we cannot use this method
        saleRateToken0 = uint112(bound(saleRateToken0, 1, type(uint112).max));
        saleRateToken1 = uint112(bound(saleRateToken1, 1, type(uint112).max));

        SqrtRatio sqrtRatioNext = calculateNextSqrtRatio({
            sqrtRatio: sqrtRatio,
            liquidity: liquidity,
            saleRateToken0: saleRateToken0,
            saleRateToken1: saleRateToken1,
            timeElapsed: timeElapsed,
            fee: fee
        });

        assertGe(sqrtRatioNext.toFixed(), MIN_SQRT_RATIO.toFixed());
        assertLe(sqrtRatioNext.toFixed(), MAX_SQRT_RATIO.toFixed());
    }
}
