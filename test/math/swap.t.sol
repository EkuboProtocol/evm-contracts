// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {AmountBeforeFeeOverflow} from "../../src/math/fee.sol";
import {Amount1DeltaOverflow} from "../../src/math/delta.sol";
import {SwapResult, SqrtRatioLimitWrongDirection, noOpSwapResult, swapResult} from "../../src/math/swap.sol";
import {isPriceIncreasing} from "../../src/math/isPriceIncreasing.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio, SqrtRatio, ONE} from "../../src/types/sqrtRatio.sol";

contract SwapTest is Test {
    function test_noOpSwapResult(SqrtRatio sqrtRatio) public pure {
        SwapResult memory result = noOpSwapResult(sqrtRatio);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.consumedAmount, 0);
        assertEq(result.feeAmount, 0);
        assertEq(SqrtRatio.unwrap(result.sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio));
    }

    function sr(
        SqrtRatio sqrtRatio,
        uint128 liquidity,
        SqrtRatio sqrtRatioLimit,
        int128 amount,
        bool isToken1,
        uint128 fee
    ) external pure returns (SwapResult memory) {
        return swapResult(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);
    }

    function test_swapResult(
        uint256 sqrtRatioFixed,
        uint128 liquidity,
        uint256 sqrtRatioLimitFixed,
        int128 amount,
        bool isToken1,
        uint128 fee
    ) public view {
        SqrtRatio sqrtRatio =
            toSqrtRatio(bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        SqrtRatio sqrtRatioLimit =
            toSqrtRatio(bound(sqrtRatioLimitFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        bool increasing = isPriceIncreasing(amount, isToken1);

        vm.assumeNoRevert();
        SwapResult memory result = this.sr(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);

        bool consumedAll = amount == result.consumedAmount;

        if (amount == 0) {
            assertEq(result.sqrtRatioNext.toFixed(), sqrtRatio.toFixed());
        } else if (increasing) {
            assertGe(result.sqrtRatioNext.toFixed(), sqrtRatio.toFixed());
            assertLe(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());

            if (consumedAll) {
                assertLe(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());
            } else {
                assertEq(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());
            }
        } else {
            assertLe(result.sqrtRatioNext.toFixed(), sqrtRatio.toFixed());
            assertGe(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());

            if (consumedAll) {
                assertGe(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());
            } else {
                assertEq(result.sqrtRatioNext.toFixed(), sqrtRatioLimit.toFixed());
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

    function test_swapResult_examples() public pure {
        SwapResult memory result = swapResult({
            sqrtRatio: ONE,
            liquidity: 100_000,
            sqrtRatioLimit: ONE,
            amount: 10_000,
            isToken1: false,
            fee: 0
        });

        assertEq(result.consumedAmount, 0);
        assertEq(result.sqrtRatioNext.toFixed(), 0x100000000000000000000000000000000);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 0);
    }

    // 1.
    function test_swap_ratio_equal_limit_token1() public pure {
        SwapResult memory result = swapResult({
            sqrtRatio: toSqrtRatio(0x100000000000000000000000000000000, false),
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio(0x100000000000000000000000000000000, false),
            amount: 10000,
            isToken1: true,
            fee: 0
        });
        assertEq(result.consumedAmount, 0);
        assertEq(result.sqrtRatioNext.toFixed(), 0x100000000000000000000000000000000);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 0);
    }

    // 2.
    function test_swap_ratio_wrong_direction_token0_input() public {
        vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
        swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + (1 << 96), false),
            amount: 10000,
            isToken1: false,
            fee: 0
        });
    }

    // 3.
    function test_swap_ratio_wrong_direction_token0_input_zero_liquidity() public {
        vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
        swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + (1 << 96), false),
            amount: 10000,
            isToken1: false,
            fee: 0
        });
    }

    // 4.
    function test_swap_ratio_wrong_direction_token0_zero_input_and_liquidity() public pure {
        SwapResult memory result = swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + (1 << 65), false),
            amount: 0,
            isToken1: false,
            fee: 0
        });
        SwapResult memory expected = noOpSwapResult(toSqrtRatio(uint256(2) << 128, false));
        assertEq(result.consumedAmount, expected.consumedAmount);
        assertEq(result.sqrtRatioNext.toFixed(), expected.sqrtRatioNext.toFixed());
        assertEq(result.calculatedAmount, expected.calculatedAmount);
        assertEq(result.feeAmount, expected.feeAmount);
    }

    // 5.
    function test_swap_ratio_wrong_direction_token0_output() public {
        vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
        swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: 0
        });
    }

    // 6.
    function test_swap_ratio_wrong_direction_token0_output_zero_liquidity() public {
        vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
        swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: 0
        });
    }

    // 7.
    function test_swap_ratio_wrong_direction_token0_zero_output_and_liquidity() public pure {
        SwapResult memory result = swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: ONE,
            amount: 0,
            isToken1: false,
            fee: 0
        });
        SwapResult memory expected = noOpSwapResult(toSqrtRatio(uint256(2) << 128, false));
        assertEq(result.consumedAmount, expected.consumedAmount);
        assertEq(result.sqrtRatioNext.toFixed(), expected.sqrtRatioNext.toFixed());
        assertEq(result.calculatedAmount, expected.calculatedAmount);
        assertEq(result.feeAmount, expected.feeAmount);
    }

    // // 8.
    // function test_swap_ratio_wrong_direction_token1_input() public {
    //     vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
    //     swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 100000,
    //         sqrtRatioLimit: SqrtRatio.wrap(0x400000000000000080000000000000000000000000000000),
    //         amount: 10000,
    //         isToken1: true,
    //         fee: 0
    //     });
    // }

    // // 9.
    // function test_swap_ratio_wrong_direction_token1_input_zero_liquidity() public {
    //     vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
    //     swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 0,
    //         sqrtRatioLimit: SqrtRatio.wrap(0x400000000000000080000000000000000000000000000000),
    //         amount: 10000,
    //         isToken1: true,
    //         fee: 0
    //     });
    // }

    // // 10.
    // function test_swap_ratio_wrong_direction_token1_zero_input_and_liquidity() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 0,
    //         sqrtRatioLimit: SqrtRatio.wrap(0x400000000000000080000000000000000000000000000000),
    //         amount: 0,
    //         isToken1: true,
    //         fee: 0
    //     });
    //     SwapResult memory expected = noOpSwapResult(uint256(2) << 128);
    //     assertEq(result.consumedAmount, expected.consumedAmount);
    //     assertEq(result.sqrtRatioNext, expected.sqrtRatioNext);
    //     assertEq(result.calculatedAmount, expected.calculatedAmount);
    //     assertEq(result.feeAmount, expected.feeAmount);
    // }

    // // 11.
    // function test_swap_ratio_wrong_direction_token1_output() public {
    //     vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
    //     swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 100000,
    //         sqrtRatioLimit: (uint256(2) << 128) + 1,
    //         amount: -10000,
    //         isToken1: true,
    //         fee: 0
    //     });
    // }

    // // 12.
    // function test_swap_ratio_wrong_direction_token1_output_zero_liquidity() public {
    //     vm.expectRevert(SqrtRatioLimitWrongDirection.selector);
    //     swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 0,
    //         sqrtRatioLimit: (uint256(2) << 128) + 1,
    //         amount: -10000,
    //         isToken1: true,
    //         fee: 0
    //     });
    // }

    // // 13.
    // function test_swap_ratio_wrong_direction_token1_zero_output_and_liquidity() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: uint256(2) << 128,
    //         liquidity: 0,
    //         sqrtRatioLimit: (uint256(2) << 128) + 1,
    //         amount: 0,
    //         isToken1: true,
    //         fee: 0
    //     });
    //     SwapResult memory expected = noOpSwapResult(uint256(2) << 128);
    //     assertEq(result.consumedAmount, expected.consumedAmount);
    //     assertEq(result.sqrtRatioNext, expected.sqrtRatioNext);
    //     assertEq(result.calculatedAmount, expected.calculatedAmount);
    //     assertEq(result.feeAmount, expected.feeAmount);
    // }

    // // 14.
    // function test_swap_against_liquidity_max_limit_token0_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 10000,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 10000);
    //     assertEq(result.sqrtRatioNext, 324078444686608060441309149935017344244);
    //     assertEq(result.calculatedAmount, 4761);
    //     assertEq(result.feeAmount, 5000);
    // }

    // // 15.
    // function test_swap_against_liquidity_max_limit_token0_minimum_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 0x100000000000000000000000000000000);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 1);
    // }

    // // 16.
    // function test_swap_against_liquidity_min_limit_token0_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: -10000,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -10000);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 0x1c71c71c71c71c71c71c71c71c71c71d;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 22224);
    //     assertEq(result.feeAmount, 11112);
    // }

    // // 17.
    // function test_swap_against_liquidity_min_limit_token0_minimum_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: -1,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -1);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 0xa7c61a3ae2bdd0cef9133bc4d7cb;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 4);
    //     assertEq(result.feeAmount, 2);
    // }

    // // 18.
    // function test_swap_against_liquidity_max_limit_token1_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: 10000,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 10000);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 17014118346046923173168730371588410572;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 4761);
    //     assertEq(result.feeAmount, 5000);
    // }

    // // 19.
    // function test_swap_against_liquidity_max_limit_token1_minimum_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 0x100000000000000000000000000000000);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 1);
    // }

    // // 20.
    // function test_swap_against_liquidity_min_limit_token1_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: -10000,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -10000);
    //     assertEq(result.sqrtRatioNext, 0xe6666666666666666666666666666666);
    //     assertEq(result.calculatedAmount, 22224);
    //     assertEq(result.feeAmount, 11112);
    // }

    // // 21.
    // function test_swap_against_liquidity_min_limit_token1_minimum_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: -1,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -1);
    //     assertEq(result.sqrtRatioNext, 0xffff583a53b8e4b87bdcf0307f23cc8d);
    //     assertEq(result.calculatedAmount, 4);
    //     assertEq(result.feeAmount, 2);
    // }

    // // 22.
    // function test_swap_against_liquidity_hit_limit_token0_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: 333476719582519694194107115283132847226,
    //         amount: 10000,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 4082);
    //     assertEq(result.sqrtRatioNext, 333476719582519694194107115283132847226);
    //     assertEq(result.calculatedAmount, 2000);
    //     assertEq(result.feeAmount, 2041);
    // }

    // // 23.
    // function test_swap_against_liquidity_hit_limit_token1_input() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: (uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85,
    //         amount: 10000,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, 4000);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 1960);
    //     assertEq(result.feeAmount, 2000);
    // }

    // // 24.
    // function test_swap_against_liquidity_hit_limit_token0_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: (uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85,
    //         amount: -10000,
    //         isToken1: false,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -1960);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 4000);
    //     assertEq(result.feeAmount, 2000);
    // }

    // // 25.
    // function test_swap_against_liquidity_hit_limit_token1_output() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: 333476719582519694194107115283132847226,
    //         amount: -10000,
    //         isToken1: true,
    //         fee: 1 << 127
    //     });
    //     assertEq(result.consumedAmount, -2000);
    //     assertEq(result.sqrtRatioNext, 333476719582519694194107115283132847226);
    //     assertEq(result.calculatedAmount, 4082);
    //     assertEq(result.feeAmount, 2041);
    // }

    // // 26.
    // function test_swap_max_amount_token0() public pure {
    //     int128 amount = type(int128).max;
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: amount,
    //         isToken1: false,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1844629699405272373741026, "consumed");
    //     assertEq(result.sqrtRatioNext, MIN_SQRT_RATIO, "sqrtRatioNext");
    //     assertEq(result.calculatedAmount, 0x1869f, "calculatedAmount");
    //     assertEq(result.feeAmount, 0, "fee");
    // }

    // // 27.
    // function test_swap_min_amount_token0() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: false,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 0xffff583ac1ac1c114b9160ddeb4791b8);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 0);
    // }

    // // 28.
    // function test_swap_min_amount_token0_very_high_price() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: MAX_SQRT_RATIO,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: false,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 34028236692093846346337460743176821145600000);
    //     assertEq(result.calculatedAmount, 1844629699405262373841025);
    //     assertEq(result.feeAmount, 0);
    // }

    // // 29.
    // function test_swap_max_amount_token1() public pure {
    //     int128 amount = type(int128).max;
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: amount,
    //         isToken1: true,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1844629699405272373741026);
    //     assertEq(result.sqrtRatioNext, 6276949602062853172742588666638147158083741740262337144812);
    //     assertEq(result.calculatedAmount, 0x1869f);
    //     assertEq(result.feeAmount, 0);
    // }

    // // 30.
    // function test_swap_min_amount_token1() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: true,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     uint256 expectedSqrt = (uint256(1) << 128) + 0xa7c5ac471b4784230fcf80dc3372;
    //     assertEq(result.sqrtRatioNext, expectedSqrt);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 0);
    // }

    // // 31.
    // function test_swap_min_amount_token1_very_high_price() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: MIN_SQRT_RATIO,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: true,
    //         fee: 0
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 3402823669209403081824910276488208);
    //     assertEq(result.calculatedAmount, 1844629699405262373841025);
    //     assertEq(result.feeAmount, 0);
    // }

    // // 32.
    // function test_swap_max_fee() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1000,
    //         isToken1: false,
    //         fee: 0xffffffffffffffffffffffffffffffff
    //     });
    //     assertEq(result.consumedAmount, 1000);
    //     assertEq(result.sqrtRatioNext, 0x100000000000000000000000000000000);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 0x3e8);
    // }

    // // 33.
    // function test_swap_min_fee() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 100000,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1000,
    //         isToken1: false,
    //         fee: 1
    //     });
    //     assertEq(result.consumedAmount, 1000);
    //     assertEq(result.sqrtRatioNext, 0xfd77c56b2369787351572278168739a1);
    //     assertEq(result.calculatedAmount, 989);
    //     assertEq(result.feeAmount, 1);
    // }

    // // 34.
    // function test_swap_all_max_inputs() public pure {
    //     int128 amount = type(int128).max;
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: MAX_SQRT_RATIO,
    //         liquidity: 0xffffffffffffffffffffffffffffffff,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: amount,
    //         isToken1: false,
    //         fee: 0xffffffffffffffffffffffffffffffff
    //     });
    //     assertEq(result.consumedAmount, amount);
    //     assertEq(result.sqrtRatioNext, MAX_SQRT_RATIO);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, uint128(amount));
    // }

    // // 35.
    // function test_swap_all_max_inputs_no_fee() public {
    //     int128 amount = type(int128).max;
    //     vm.expectRevert(Amount1DeltaOverflow.selector);
    //     swapResult({
    //         sqrtRatio: MAX_SQRT_RATIO,
    //         liquidity: 0xffffffffffffffffffffffffffffffff,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: amount,
    //         isToken1: false,
    //         fee: 0
    //     });
    // }

    // // 36.
    // function test_swap_result_example_usdc_wbtc() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 21175949444679574865522613902772161611,
    //         liquidity: 717193642384,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 9995000000,
    //         isToken1: false,
    //         fee: 1020847100762815411640772995208708096
    //     });
    //     assertEq(result.consumedAmount, 9995000000);
    //     assertEq(result.sqrtRatioNext, 0xfead0f195a1008a61a0a6a34c2b5410);
    //     assertEq(result.calculatedAmount, 38557555);
    //     assertEq(result.feeAmount, 29985001);
    // }

    // // 37.
    // function test_exact_output_swap_max_fee_token0() public {
    //     vm.expectRevert(AmountBeforeFeeOverflow.selector);
    //     swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: -1,
    //         isToken1: false,
    //         fee: type(uint128).max
    //     });
    // }

    // // 38.
    // function test_exact_output_swap_max_fee_large_amount_token0() public {
    //     vm.expectRevert(AmountBeforeFeeOverflow.selector);
    //     swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: -10000,
    //         isToken1: false,
    //         fee: type(uint128).max
    //     });
    // }

    // // 39.
    // function test_exact_output_swap_max_fee_token0_limit_reached() public {
    //     vm.expectRevert(AmountBeforeFeeOverflow.selector);
    //     swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: (uint256(1) << 128) + 0x200000000,
    //         amount: -1,
    //         isToken1: false,
    //         fee: type(uint128).max
    //     });
    // }

    // // 40.
    // function test_exact_output_swap_max_fee_token1() public {
    //     vm.expectRevert(AmountBeforeFeeOverflow.selector);
    //     swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: -1,
    //         isToken1: true,
    //         fee: type(uint128).max
    //     });
    // }

    // // 41.
    // function test_exact_output_swap_max_fee_token1_limit_reached() public {
    //     vm.expectRevert(AmountBeforeFeeOverflow.selector);
    //     swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: toSqrtRatio(0xffffffffffffffffffffffff00000000),
    //         amount: -1,
    //         isToken1: true,
    //         fee: type(uint128).max
    //     });
    // }

    // // 42.
    // function test_exact_input_swap_max_fee_token0() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: MIN_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: false,
    //         fee: type(uint128).max
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 0x100000000000000000000000000000000);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 1);
    // }

    // // 43.
    // function test_exact_input_swap_max_fee_token1() public pure {
    //     SwapResult memory result = swapResult({
    //         sqrtRatio: 0x100000000000000000000000000000000,
    //         liquidity: 79228162514264337593543950336,
    //         sqrtRatioLimit: MAX_SQRT_RATIO,
    //         amount: 1,
    //         isToken1: true,
    //         fee: type(uint128).max
    //     });
    //     assertEq(result.consumedAmount, 1);
    //     assertEq(result.sqrtRatioNext, 0x100000000000000000000000000000000);
    //     assertEq(result.calculatedAmount, 0);
    //     assertEq(result.feeAmount, 1);
    // }
}
