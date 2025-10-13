// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    computeSaleRate,
    computeNextSqrtRatio,
    computeC,
    computeAmountFromSaleRate,
    computeSqrtSaleRatio,
    computeRewardAmount,
    addSaleRateDelta,
    SaleRateDeltaOverflow,
    SaleRateOverflow
} from "../../src/math/twamm.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";

contract TwammMathTest is Test {
    function test_computeSaleRate_examples() public pure {
        assertEq(computeSaleRate(1000, 5), (1000 << 32) / 5);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_computeSaleRate_fuzz(uint128 amount, uint32 duration) public {
        duration = uint32(bound(duration, 1, type(uint32).max));
        uint256 saleRate = (uint256(amount) << 32) / duration;

        if (saleRate > type(uint112).max) {
            vm.expectRevert(SaleRateOverflow.selector);
        }
        uint256 result = computeSaleRate(amount, duration);
        assertEq(result, saleRate);
    }

    function wrapped_addSaleRateDelta(uint112 saleRate, int112 delta) external pure {
        addSaleRateDelta(saleRate, delta);
    }

    function test_addSaleRateDelta_invariants(uint112 saleRate, int112 delta) public {
        int256 expected = int256(uint256(saleRate)) + delta;
        if (expected < 0 || expected > int256(uint256(type(uint112).max))) {
            vm.expectRevert(SaleRateDeltaOverflow.selector);
            this.wrapped_addSaleRateDelta(saleRate, delta);
        } else {
            uint256 result = addSaleRateDelta(saleRate, delta);
            assertEq(int256(uint256(result)), expected);
        }
    }

    function test_computeRewardAmount() public pure {
        assertEq(computeRewardAmount({rewardRate: 0, saleRate: 0}), 0);
        assertEq(computeRewardAmount({rewardRate: type(uint256).max, saleRate: 0}), 0);
        assertEq(computeRewardAmount({rewardRate: type(uint256).max, saleRate: 1}), type(uint128).max);
        assertEq(computeRewardAmount({rewardRate: type(uint256).max, saleRate: type(uint112).max}), type(uint128).max);
        // overflows the uint128 container
        assertEq(computeRewardAmount({rewardRate: 1 << 146, saleRate: 1 << 110}), 0);
    }

    function test_computeAmountFromSaleRate_examples() public pure {
        // 100 per second
        assertEq(computeAmountFromSaleRate({saleRate: 100 << 32, duration: 3, roundUp: false}), 300);
        assertEq(computeAmountFromSaleRate({saleRate: 100 << 32, duration: 3, roundUp: true}), 300);

        // 62.5 per second
        assertEq(computeAmountFromSaleRate({saleRate: 125 << 31, duration: 3, roundUp: false}), 187);
        assertEq(computeAmountFromSaleRate({saleRate: 125 << 31, duration: 3, roundUp: true}), 188);

        // nearly 0 per second
        assertEq(computeAmountFromSaleRate({saleRate: 1, duration: 3, roundUp: false}), 0);
        assertEq(computeAmountFromSaleRate({saleRate: 1, duration: 3, roundUp: true}), 1);

        // nearly 0 per second
        assertEq(computeAmountFromSaleRate({saleRate: 1, duration: type(uint32).max, roundUp: false}), 0);
        assertEq(computeAmountFromSaleRate({saleRate: 1, duration: type(uint32).max, roundUp: true}), 1);

        // max sale rate max duration
        assertEq(
            computeAmountFromSaleRate({saleRate: type(uint112).max, duration: type(uint32).max, roundUp: false}),
            5192296857325901808915867154513919
        );
        assertEq(
            computeAmountFromSaleRate({saleRate: type(uint112).max, duration: type(uint32).max, roundUp: true}),
            5192296857325901808915867154513920
        );
    }

    function test_computeC_examples() public pure {
        assertEq(computeC(1 << 128, 1 << 129), 113427455640312821154458202477256070485);
        assertEq(computeC(1 << 128, 1 << 127), -113427455640312821154458202477256070485);
        assertEq(computeC(1 << 128, 1 << 128), 0);

        // large difference
        assertEq(
            computeC(MAX_SQRT_RATIO.toFixed(), MIN_SQRT_RATIO.toFixed()),
            -340282366920938463463374607431768211453,
            "max,min"
        );
        assertEq(
            computeC(MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()),
            340282366920938463463374607431768211453,
            "min,max"
        );

        // small difference, i.e. large denominator relative to numerator
        assertEq(computeC(MAX_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed() - 1), 0, "max,max-1");
        assertEq(computeC(MIN_SQRT_RATIO.toFixed() + 1, MIN_SQRT_RATIO.toFixed()), -9223148497026361869, "min,min+1");

        assertEq(computeC({sqrtRatio: 10, sqrtSaleRatio: 15}), 0x33333333333333333333333333333333);
        assertEq(computeC({sqrtRatio: 10, sqrtSaleRatio: 20}), 0x55555555555555555555555555555555);
        assertEq(computeC({sqrtRatio: 10, sqrtSaleRatio: 30}), 0x80000000000000000000000000000000);
        assertEq(computeC({sqrtRatio: 10, sqrtSaleRatio: 190}), 0xe6666666666666666666666666666666);

        assertEq(computeC({sqrtRatio: 15, sqrtSaleRatio: 10}), -0x33333333333333333333333333333333);
        assertEq(computeC({sqrtRatio: 20, sqrtSaleRatio: 10}), -0x55555555555555555555555555555555);
        assertEq(computeC({sqrtRatio: 30, sqrtSaleRatio: 10}), -0x80000000000000000000000000000000);
        assertEq(computeC({sqrtRatio: 190, sqrtSaleRatio: 10}), -0xe6666666666666666666666666666666);
    }

    function test_computeSqrtSaleRatio_examples() public pure {
        assertEq(computeSqrtSaleRatio(1, 1), uint256(1) << 128);
        assertEq(computeSqrtSaleRatio(100, 1), 34028236692093846346337460743176821142);
        assertEq(computeSqrtSaleRatio(1, 100), 3402823669209384634633746074317682114560);
        assertEq(computeSqrtSaleRatio(type(uint112).max, 1), 4722366482869645213696);
        assertEq(computeSqrtSaleRatio(1, type(uint112).max), 24519928653854221733733552434404944576644526926077100032);
    }

    function test_gas_cost_computeNextSqrtRatio() public {
        vm.startSnapshotGas("computeNextSqrtRatio_0");
        computeNextSqrtRatio({
            sqrtRatio: toSqrtRatio(10_000 << 128, false),
            liquidity: 10_000,
            saleRateToken0: 458864027,
            saleRateToken1: 280824784,
            timeElapsed: 46_800,
            fee: 0
        });
        vm.stopSnapshotGas();

        vm.startSnapshotGas("computeNextSqrtRatio_1");
        computeNextSqrtRatio({
            sqrtRatio: toSqrtRatio((uint256(1) << 128) / 10_000, false),
            liquidity: 1_000_000,
            saleRateToken0: 707 << 32,
            saleRateToken1: 179 << 32,
            timeElapsed: 12,
            fee: uint64((uint256(30) << 64) / 10_000)
        });
        vm.stopSnapshotGas();

        vm.startSnapshotGas("computeNextSqrtRatio_2");
        computeNextSqrtRatio({
            sqrtRatio: toSqrtRatio(286363514177267035440548892163466107483369185, false),
            liquidity: 130385243018985227,
            saleRateToken0: 1917585044284,
            saleRateToken1: 893194653345642013054241177,
            timeElapsed: 360,
            fee: 922337203685477580
        });
        vm.stopSnapshotGas();
    }

    function test_computeNextSqrtRatio_examples() public pure {
        assertEq(
            computeNextSqrtRatio({
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
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio((uint256(1) << 128) / 10_000, false),
                liquidity: 1_000_000,
                saleRateToken0: 707 << 32,
                saleRateToken1: 179 << 32,
                timeElapsed: 12,
                fee: uint64((uint256(30) << 64) / 10_000)
            }).toFixed(),
            762756935888947507319423427130949632 // 0.00224154117297
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 100_000 << 32,
                saleRateToken1: 1 << 32,
                timeElapsed: 12,
                fee: 1 << 63
            }).toFixed(),
            212677851090737004084435068911850881024 // 0.625004031255463
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 100_000 << 32,
                saleRateToken1: 1 << 32,
                timeElapsed: 12,
                fee: 0
            }).toFixed(),
            154676064193352917823625393341053534208 // 0.4545520992
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 1 << 32,
                saleRateToken1: 100_000 << 32,
                timeElapsed: 12,
                fee: 1 << 63
            }).toFixed(),
            544448275377366823331338723279895527424 // 1.5999896801
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(uint256(1) << 128, false),
                liquidity: 1_000_000,
                saleRateToken0: 1 << 32,
                saleRateToken1: 100_000 << 32,
                timeElapsed: 12,
                fee: 0
            }).toFixed(),
            748610263916272246100204618056279785472 // 2.1999678405
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(286363514177267035440548892163466107483369185, false),
                liquidity: 130385243018985227,
                saleRateToken0: 1917585044284,
                saleRateToken1: 893194653345642013054241177,
                timeElapsed: 360,
                fee: 922337203685477580
            }).toFixed(),
            286548851173856260703560045093187956263354368 // 842,091.3894737111
        );

        assertEq(
            computeNextSqrtRatio({
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
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(286363514177267035440548892163466107483369185, false),
                liquidity: 130385243018985227,
                saleRateToken0: 1917585044284,
                saleRateToken1: 893194653345642013054241177,
                timeElapsed: 360,
                fee: 922337203685477580
            }).toFixed(),
            286548851173856260703560045093187956263354368 // 842,091.3894737111
        );

        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(404353500025976246415094160170803, false),
                liquidity: 130385243018985227,
                saleRateToken0: 893194653345642013054241177,
                saleRateToken1: 1917585044284,
                timeElapsed: 360,
                fee: 922337203685477580
            }).toFixed(),
            404091968133776522675682963095552 // 842,091.3894737111
        );

        assertEq(
            computeNextSqrtRatio({
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

    function test_computeNextSqrtRatio_example_from_production() public pure {
        assertEq(
            computeNextSqrtRatio({
                sqrtRatio: toSqrtRatio(4182607738901102592 + (148436996701757 << 64), false),
                liquidity: 4472135213867,
                saleRateToken0: 3728260255814876407785,
                saleRateToken1: 1597830095238095,
                timeElapsed: 2688,
                fee: 9223372036854775
            }).toFixed(),
            75660834358443397537995245133758464
        );
    }

    function test_computeNextSqrtRatio_always_within_bounds_0() public pure {
        test_computeNextSqrtRatio_always_within_bounds(
            40804391198510682395386066027183367945789451008295010214769,
            417285290670760742141,
            type(uint112).max,
            1,
            type(uint32).max,
            0
        );
    }

    function test_computeNextSqrtRatio_always_within_bounds(
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

        SqrtRatio sqrtRatioNext = computeNextSqrtRatio({
            sqrtRatio: sqrtRatio,
            liquidity: liquidity,
            saleRateToken0: saleRateToken0,
            saleRateToken1: saleRateToken1,
            timeElapsed: timeElapsed,
            fee: fee
        });

        // it should always be within the min/max sqrt ratio which represents 2**-128 to 2**128
        // this is because the sale ratio is bounded to 2**-112 to 2**112
        assertGe(sqrtRatioNext.toFixed(), MIN_SQRT_RATIO.toFixed());
        assertLe(sqrtRatioNext.toFixed(), MAX_SQRT_RATIO.toFixed());

        uint256 sqrtSaleRatio = computeSqrtSaleRatio(saleRateToken0, saleRateToken1);

        // the next sqrt ratio is always between the sale ratio and current price
        if (sqrtSaleRatio > sqrtRatio.toFixed()) {
            assertGe(sqrtRatioNext.toFixed(), sqrtRatio.toFixed());
            assertLe(sqrtRatioNext.toFixed(), sqrtSaleRatio);

            if (liquidity == 0) {
                assertEq(sqrtRatioNext.toFixed(), toSqrtRatio(sqrtSaleRatio, false).toFixed());
            }
        } else {
            assertLe(sqrtRatioNext.toFixed(), sqrtRatio.toFixed());
            assertGe(sqrtRatioNext.toFixed(), sqrtSaleRatio);

            if (liquidity == 0) {
                assertEq(sqrtRatioNext.toFixed(), toSqrtRatio(sqrtSaleRatio, true).toFixed());
            }
        }
    }
}
