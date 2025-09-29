// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ICore} from "../../src/interfaces/ICore.sol";
import {Test} from "forge-std/Test.sol";
import {Amount1DeltaOverflow} from "../../src/math/delta.sol";
import {isPriceIncreasing} from "../../src/math/isPriceIncreasing.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio, SqrtRatio, ONE} from "../../src/types/sqrtRatio.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {FullTest} from "../FullTest.sol";

/// @notice Result of a swap calculation
/// @dev Contains all the information needed to execute a swap
struct SwapResult {
    /// @notice Amount of the input token consumed by the swap
    int128 consumedAmount;
    /// @notice Amount of the output token calculated from the swap
    uint128 calculatedAmount;
    /// @notice The new sqrt price ratio after the swap
    SqrtRatio sqrtRatioNext;
    /// @notice Amount of fees collected from the swap
    uint128 feeAmount;
}

/// @notice Creates a no-operation swap result
/// @dev Used when a swap would have no effect (zero amount or already at limit price)
/// @param sqrtRatioNext The sqrt price ratio to use in the result
/// @return A SwapResult with zero amounts and the provided sqrt ratio
function noOpSwapResult(SqrtRatio sqrtRatioNext) pure returns (SwapResult memory) {
    return SwapResult({consumedAmount: 0, calculatedAmount: 0, feeAmount: 0, sqrtRatioNext: sqrtRatioNext});
}

contract SwapTest is FullTest {
    function setUp() public override {
        FullTest.setUp();
    }

    function test_noOpSwapResult(SqrtRatio sqrtRatio) public pure {
        SwapResult memory result = noOpSwapResult(sqrtRatio);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.consumedAmount, 0);
        assertEq(result.feeAmount, 0);
        assertEq(SqrtRatio.unwrap(result.sqrtRatioNext), SqrtRatio.unwrap(sqrtRatio));
    }

    function swapResult(
        SqrtRatio sqrtRatio,
        uint128 liquidity,
        SqrtRatio sqrtRatioLimit,
        int128 amount,
        bool isToken1,
        uint64 fee
    ) external returns (SwapResult memory) {
        PoolKey memory poolKey = createPool({tick: 0, tickSpacing: 0, fee: fee});
        // move starting price to the
        router.swap({
            isToken1: false,
            amount: type(int128).min,
            sqrtRatioLimit: sqrtRatio,
            skipAhead: 0,
            calculatedAmountThreshold: type(int128).min,
            recipient: address(0)
        });
    }

    function test_swapResult(
        uint256 sqrtRatioFixed,
        uint128 liquidity,
        uint256 sqrtRatioLimitFixed,
        int128 amount,
        bool isToken1,
        uint64 fee
    ) public {
        SqrtRatio sqrtRatio =
            toSqrtRatio(bound(sqrtRatioFixed, MIN_SQRT_RATIO.toFixed(), MAX_SQRT_RATIO.toFixed()), false);
        bool increasing = isPriceIncreasing(amount, isToken1);
        // put the sqrt ratio limit in the right direction
        SqrtRatio sqrtRatioLimit = increasing
            ? toSqrtRatio(bound(sqrtRatioLimitFixed, sqrtRatio.toFixed(), MAX_SQRT_RATIO.toFixed()), true)
            : toSqrtRatio(bound(sqrtRatioLimitFixed, MIN_SQRT_RATIO.toFixed(), sqrtRatio.toFixed()), false);

        vm.assumeNoRevert();
        SwapResult memory result = this.swapResult(sqrtRatio, liquidity, sqrtRatioLimit, amount, isToken1, fee);

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

    function test_swapResult_examples() public {
        SwapResult memory result = this.swapResult({
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

    function test_swap_ratio_equal_limit_token1() public {
        SwapResult memory result = this.swapResult({
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

    function test_swap_ratio_wrong_direction_token0_input() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + (1 << 96), false),
            amount: 10000,
            isToken1: false,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token0_input_zero_liquidity() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + (1 << 96), false),
            amount: 10000,
            isToken1: false,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token0_zero_input_and_liquidity() public {
        SwapResult memory result = this.swapResult({
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

    function test_swap_ratio_wrong_direction_token0_output() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token0_output_zero_liquidity() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token0_zero_output_and_liquidity() public {
        SwapResult memory result = this.swapResult({
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

    function test_swap_ratio_wrong_direction_token1_input() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio(0x100000000000000000000000000000000, false),
            amount: 10000,
            isToken1: true,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token1_input_zero_liquidity() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio(0x100000000000000000000000000000000, false),
            amount: 10000,
            isToken1: true,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token1_zero_input_and_liquidity() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio(0x100000000000000000000000000000000, false),
            amount: 0,
            isToken1: true,
            fee: 0
        });
        SwapResult memory expected = noOpSwapResult(toSqrtRatio(uint256(2) << 128, false));
        assertEq(result.consumedAmount, expected.consumedAmount);
        assertEq(result.sqrtRatioNext.toFixed(), expected.sqrtRatioNext.toFixed());
        assertEq(result.calculatedAmount, expected.calculatedAmount);
        assertEq(result.feeAmount, expected.feeAmount);
    }

    function test_swap_ratio_wrong_direction_token1_output() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + 1, true),
            amount: -10000,
            isToken1: true,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token1_output_zero_liquidity() public {
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + 1, true),
            amount: -10000,
            isToken1: true,
            fee: 0
        });
    }

    function test_swap_ratio_wrong_direction_token1_zero_output_and_liquidity() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: toSqrtRatio(uint256(2) << 128, false),
            liquidity: 0,
            sqrtRatioLimit: toSqrtRatio((uint256(2) << 128) + 1, true),
            amount: 0,
            isToken1: true,
            fee: 0
        });
        SwapResult memory expected = noOpSwapResult(toSqrtRatio(uint256(2) << 128, false));
        assertEq(result.consumedAmount, expected.consumedAmount);
        assertTrue(result.sqrtRatioNext == expected.sqrtRatioNext);
        assertEq(result.calculatedAmount, expected.calculatedAmount);
        assertEq(result.feeAmount, expected.feeAmount);
    }

    function test_swap_against_liquidity_max_limit_token0_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: toSqrtRatio(0x100000000000000000000000000000000, false),
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 10000,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 10000);
        assertEq(result.sqrtRatioNext.toFixed(), 324078444686608060441309149948106768384);
        assertEq(result.calculatedAmount, 4761);
        assertEq(result.feeAmount, 5000);
    }

    function test_swap_against_liquidity_max_limit_token0_minimum_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == ONE);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 1);
    }

    function test_swap_against_liquidity_min_limit_token0_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -10000);
        assertEq(result.sqrtRatioNext.toFixed(), 378091518801042737222520106199097016320);
        assertEq(result.calculatedAmount, 22224);
        assertEq(result.feeAmount, 11112);
    }

    function test_swap_against_liquidity_min_limit_token0_minimum_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: -1,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -1);
        assertEq(result.sqrtRatioNext.toFixed(), 340285769778636249866166861115464613888);
        assertEq(result.calculatedAmount, 4);
        assertEq(result.feeAmount, 2);
    }

    function test_swap_against_liquidity_max_limit_token1_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 10000,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 10000);
        SqrtRatio expectedSqrt = toSqrtRatio((uint256(1) << 128) + 17014118346046923173168730371588410572, false);
        assertTrue(result.sqrtRatioNext == expectedSqrt);
        assertEq(result.calculatedAmount, 4761);
        assertEq(result.feeAmount, 5000);
    }

    function test_swap_against_liquidity_max_limit_token1_minimum_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 1,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == ONE);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 1);
    }

    function test_swap_against_liquidity_min_limit_token1_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -10000,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -10000);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(0xe6666666666666666666666666666666, false));
        assertEq(result.calculatedAmount, 22224);
        assertEq(result.feeAmount, 11112);
    }

    function test_swap_against_liquidity_min_limit_token1_minimum_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -1,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -1);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(0xffff583a53b8e4b87bdcf0307f23cc8d, false));
        assertEq(result.calculatedAmount, 4);
        assertEq(result.feeAmount, 2);
    }

    function test_swap_against_liquidity_hit_limit_token0_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio(333476719582519694194107115283132847226, false),
            amount: 10000,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 4082);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(333476719582519694194107115283132847226, false));
        assertEq(result.calculatedAmount, 2000);
        assertEq(result.feeAmount, 2041);
    }

    function test_swap_against_liquidity_hit_limit_token1_input() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio((uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85, false),
            amount: 10000,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, 4000);
        SqrtRatio expectedSqrt = toSqrtRatio((uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85, false);
        assertTrue(result.sqrtRatioNext == expectedSqrt);
        assertEq(result.calculatedAmount, 1960);
        assertEq(result.feeAmount, 2000);
    }

    function test_swap_against_liquidity_hit_limit_token0_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio((uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85, false),
            amount: -10000,
            isToken1: false,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -1960);
        SqrtRatio expectedSqrt = toSqrtRatio((uint256(1) << 128) + 0x51eb851eb851eb851eb851eb851eb85, false);
        assertTrue(result.sqrtRatioNext == expectedSqrt);
        assertEq(result.calculatedAmount, 4000);
        assertEq(result.feeAmount, 2000);
    }

    function test_swap_against_liquidity_hit_limit_token1_output() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: toSqrtRatio(333476719582519694194107115283132847226, false),
            amount: -10000,
            isToken1: true,
            fee: 1 << 63
        });
        assertEq(result.consumedAmount, -2000);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(333476719582519694194107115283132847226, false));
        assertEq(result.calculatedAmount, 4082);
        assertEq(result.feeAmount, 2041);
    }

    function test_swap_max_amount_token0() public {
        int128 amount = type(int128).max;
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: amount,
            isToken1: false,
            fee: 0
        });
        assertEq(result.consumedAmount, 1844629699405272373941017, "consumed");
        assertTrue(result.sqrtRatioNext == MIN_SQRT_RATIO, "sqrtRatioNext");
        assertEq(result.calculatedAmount, 0x1869f, "calculatedAmount");
        assertEq(result.feeAmount, 0, "fee");
    }

    function test_swap_min_amount_token0() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1,
            isToken1: false,
            fee: 0
        });
        assertEq(result.consumedAmount, 1);
        assertEq(result.sqrtRatioNext.toFixed(), 340278964131297150491869688743818428416);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 0);
    }

    function test_swap_min_amount_token0_very_high_price() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: MAX_SQRT_RATIO,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1,
            isToken1: false,
            fee: 0
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(34028236692093846346337460743176821145600000, false));
        assertEq(result.calculatedAmount, 1844629699405262373841025);
        assertEq(result.feeAmount, 0);
    }

    function test_swap_max_amount_token1() public {
        int128 amount = type(int128).max;
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: amount,
            isToken1: true,
            fee: 0
        });
        assertEq(result.consumedAmount, 1844629699405272373741026);
        assertTrue(
            result.sqrtRatioNext == toSqrtRatio(6276949602062853172742588666638147158083741740262337144812, false)
        );
        assertEq(result.calculatedAmount, 0x1869f);
        assertEq(result.feeAmount, 0);
    }

    function test_swap_min_amount_token1() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 1,
            isToken1: true,
            fee: 0
        });
        assertEq(result.consumedAmount, 1);
        SqrtRatio expectedSqrt = toSqrtRatio((uint256(1) << 128) + 0xa7c5ac471b4784230fcf80dc3372, false);
        assertTrue(result.sqrtRatioNext == expectedSqrt);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 0);
    }

    function test_swap_min_amount_token1_very_high_price() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: MIN_SQRT_RATIO,
            liquidity: 100000,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 1,
            isToken1: true,
            fee: 0
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == toSqrtRatio(3402823669209403081824910276488208, false));
        assertEq(result.calculatedAmount, 1844629699405262374041016);
        assertEq(result.feeAmount, 0);
    }

    function test_swap_max_fee() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1000,
            isToken1: false,
            fee: type(uint64).max
        });
        assertEq(result.consumedAmount, 1000);
        assertTrue(result.sqrtRatioNext == ONE);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 0x3e8);
    }

    function test_swap_min_fee() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 100000,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1000,
            isToken1: false,
            fee: 1
        });
        assertEq(result.consumedAmount, 1000);
        assertEq(result.sqrtRatioNext.toFixed(), 336916570382814150103837273090563244032);
        assertEq(result.calculatedAmount, 989);
        assertEq(result.feeAmount, 1);
    }

    function test_swap_all_max_inputs() public {
        vm.expectRevert(Amount1DeltaOverflow.selector);
        this.swapResult({
            sqrtRatio: MAX_SQRT_RATIO,
            liquidity: 0xffffffffffffffffffffffffffffffff,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: type(int128).max,
            isToken1: false,
            fee: type(uint64).max
        });
    }

    function test_swap_all_max_inputs_no_fee() public {
        int128 amount = type(int128).max;
        vm.expectRevert(Amount1DeltaOverflow.selector);
        this.swapResult({
            sqrtRatio: MAX_SQRT_RATIO,
            liquidity: 0xffffffffffffffffffffffffffffffff,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: amount,
            isToken1: false,
            fee: 0
        });
    }

    function test_swap_result_example_usdc_wbtc() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: toSqrtRatio(21175949444679574865522613902772161611, false),
            liquidity: 717193642384,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 9995000000,
            isToken1: false,
            fee: 55340232221128654
        });
        assertEq(result.consumedAmount, 9995000000);
        assertEq(result.sqrtRatioNext.toFixed(), 21157655283161685063980137627317698560);
        assertEq(result.calculatedAmount, 38557555);
        assertEq(result.feeAmount, 29985000);
    }

    function test_exact_output_swap_max_fee_token0() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: -1,
            isToken1: false,
            fee: type(uint64).max
        });

        assertEq(result.consumedAmount, -1);
        assertEq(result.calculatedAmount, 316912650057057350374175801344);
        assertEq(result.feeAmount, 316912650057057350356995932160);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938463537161583726606417920);
    }

    function test_exact_output_swap_max_fee_large_amount_token0() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: -10000,
            isToken1: false,
            fee: type(uint64).max
        });

        assertEq(result.consumedAmount, -10000);
        assertEq(result.calculatedAmount, 316912650057057350374175801344);
        assertEq(result.feeAmount, 316912650057057350356995932160);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938463537161583726606417920);
    }

    function test_exact_output_swap_max_fee_token0_limit_reached() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: toSqrtRatio((uint256(1) << 128) + 0x200000000, true),
            amount: -1,
            isToken1: false,
            fee: type(uint64).max
        });

        assertEq(result.consumedAmount, -1);
        assertEq(result.calculatedAmount, 316912650057057350374175801344);
        assertEq(result.feeAmount, 316912650057057350356995932160);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938463537161583726606417920);
    }

    function test_exact_output_swap_max_fee_token1() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: -1,
            isToken1: true,
            fee: type(uint64).max
        });
        assertEq(result.consumedAmount, -1);
        assertEq(result.calculatedAmount, 92233720368547758080);
        assertEq(result.feeAmount, 92233720368547758075);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938463463374607414588342272); // ~= 1
    }

    function test_exact_output_swap_max_fee_token1_limit_reached() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: toSqrtRatio(0xffffffffffffffffffffffff00000000, false),
            amount: -1,
            isToken1: true,
            fee: type(uint64).max
        });

        assertEq(result.consumedAmount, -1);
        assertEq(result.calculatedAmount, 92233720368547758080);
        assertEq(result.feeAmount, 92233720368547758075);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938463463374607414588342272);
    }

    function test_exact_input_swap_max_fee_token0() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1,
            isToken1: false,
            fee: type(uint64).max
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == ONE);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 1);
    }

    function test_exact_input_swap_max_fee_token1() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            liquidity: 79228162514264337593543950336,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 1,
            isToken1: true,
            fee: type(uint64).max
        });
        assertEq(result.consumedAmount, 1);
        assertTrue(result.sqrtRatioNext == ONE);
        assertEq(result.calculatedAmount, 0);
        assertEq(result.feeAmount, 1);
    }

    function test_large_liquidity_rounding_price_eg_usdc_usdt_token1() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            // e.g. $100m of USDC/USDT at max concentration (2e6 concentrated)
            liquidity: 100_000_000e6 * 2e6,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            amount: 1e6, // 1 of token1
            isToken1: true,
            fee: uint64((uint256(1) << 64) / 10_000) // .01%
        });
        assertEq(result.consumedAmount, 1e6);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920940164695900061221456445440);
        assertEq(result.calculatedAmount, 999894);
        assertEq(result.feeAmount, 100);
    }

    function test_large_liquidity_rounding_price_eg_usdc_usdt_token0() public {
        SwapResult memory result = this.swapResult({
            sqrtRatio: ONE,
            // e.g. $100m of USDC/USDT at max concentration (2e6 concentrated)
            liquidity: 100_000_000e6 * 2e6,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            amount: 1000,
            isToken1: false,
            fee: uint64((uint256(1) << 64) / 10_000) // .01%
        });
        assertEq(result.consumedAmount, 1000);
        assertEq(result.sqrtRatioNext.toFixed(), 340282366920938461763664184673493319680);
        assertEq(result.calculatedAmount, 998);
        assertEq(result.feeAmount, 1);
    }

    function test_large_liquidity_rounding_price_eg_eth_wbtc_token1() public {
        SwapResult memory result = this.swapResult({
            // floor(sqrt((1/35.9646)*(10**8 / 10**18)) * 2**128)
            sqrtRatio: toSqrtRatio(567416326511680895821092960597055, false),
            // e.g. $100m of WBTC/ETH at max concentration (2e6 concentrated)
            // floor(sqrt(1000e8 * 37037e18))
            liquidity: 60858031515979877 * 2e6,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            // 1 wbtc should be about 35 eth
            amount: 1e8,
            isToken1: true,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, 1e8);
        assertEq(result.sqrtRatioNext.toFixed(), 567416326791111742716100667768832);
        assertEq(result.calculatedAmount, 35.946617682297259606e18);
        assertEq(result.feeAmount, 50000);
    }

    function test_large_liquidity_rounding_price_eg_eth_wbtc_eth_in_token0() public {
        SwapResult memory result = this.swapResult({
            // floor(sqrt((1/35.9646)*(10**8 / 10**18)) * 2**128)
            sqrtRatio: toSqrtRatio(567416326511680895821092960597055, false),
            // e.g. $100m of WBTC/ETH at max concentration (2e6 concentrated)
            // floor(sqrt(1000e8 * 37037e18))
            liquidity: 60858031515979877 * 2e6,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            // 1 wbtc should be about 35 eth
            amount: 100e18,
            isToken1: false,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, 100e18);
        assertEq(result.sqrtRatioNext.toFixed(), 567416325734720088492796473769984);
        assertEq(result.calculatedAmount, 2.77912168e8);
        assertEq(result.feeAmount, 49999999999999996);
    }

    function test_unrealistic_large_liquidity_rounding_token0_in_high_price() public {
        SwapResult memory result = this.swapResult({
            // price of 2**96
            // floor(sqrt(2**96) * 2**128) == 2**176
            sqrtRatio: toSqrtRatio(1 << 176, false),
            liquidity: type(uint128).max,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            // 1e-18 token0
            amount: 100,
            isToken1: false,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, 100);
        assertEq(result.sqrtRatioNext.toFixed(), 95780971304118053647389083293292954599762214917242880);
        assertEq(result.calculatedAmount, 7_605_903_601_369_376_408_980_219_232_255); // approximately 100 input - 1 fee * 2**96 price == 7.9228162514E30
        assertEq(result.feeAmount, 1);
    }

    function test_unrealistic_large_liquidity_rounding_token1_in_high_price() public {
        SwapResult memory result = this.swapResult({
            // price of 2**96
            // floor(sqrt(2**96) * 2**128) == 2**176
            sqrtRatio: toSqrtRatio(1 << 176, false),
            liquidity: type(uint128).max,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            // 1 token1
            amount: type(int128).max,
            isToken1: true,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, type(int128).max);
        assertEq(result.sqrtRatioNext.toFixed(), 95780971304118223703509385535409808758432655611002880);
        assertEq(result.calculatedAmount, 2_146_409_903); // approximately 2**127 input / 2**96 price == 2,147,483,648
        assertEq(result.feeAmount, 85070591730234608413359046079283200);
    }

    function test_unrealistic_large_liquidity_rounding_token0_in_low_price() public {
        SwapResult memory result = this.swapResult({
            // price of 2**96
            // floor(sqrt(1/2**96) * 2**128) == 2**80
            sqrtRatio: toSqrtRatio(1 << 80, false),
            liquidity: type(uint128).max,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            // 1e-18 token0
            amount: 100,
            isToken1: true,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, 100);
        assertEq(result.sqrtRatioNext.toFixed(), 1208925819614629174706272);
        assertEq(result.calculatedAmount, 7_605_903_601_369_376_408_979_615_252_479); // approximately 100 input - 1 fee * 2**96 price == 7.9228162514E30
        assertEq(result.feeAmount, 1);
    }

    function test_unrealistic_large_liquidity_rounding_token1_in_low_price() public {
        SwapResult memory result = this.swapResult({
            // price of 2**96
            // floor(sqrt(2**96) * 2**128) == 2**176
            sqrtRatio: toSqrtRatio(1 << 80, false),
            liquidity: type(uint128).max,
            sqrtRatioLimit: MIN_SQRT_RATIO,
            // 1 token1
            amount: type(int128).max,
            isToken1: false,
            fee: uint64((uint256(5) << 64) / 10_000) // .05%
        });
        assertEq(result.consumedAmount, type(int128).max);
        assertEq(result.sqrtRatioNext.toFixed(), 1208925819614627028296272);
        assertEq(result.calculatedAmount, 2_146_409_903); // approximately 2**127 input / 2**96 price == 2,147,483,648
        assertEq(result.feeAmount, 85070591730234608413359046079283200);
    }
}
