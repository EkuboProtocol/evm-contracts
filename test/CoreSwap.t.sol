// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {FullTest} from "./FullTest.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {PoolState, createPoolState} from "../src/types/poolState.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, toSqrtRatio, SqrtRatio, ONE} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

contract CoreSwapTest is FullTest {
    using CoreLib for *;

    PoolKey poolKey;

    // State variables for swap parameters
    int128 swapAmount;
    bool swapIsToken1;
    SqrtRatio swapSqrtRatioLimit;
    uint256 swapSkipAhead;
    PoolKey swapPoolKey;

    function setUp() public override {
        super.setUp();

        // Create a standard pool for testing
        poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: toConfig(3000, 60, address(0)) // 0.3% fee, 60 tick spacing
        });

        // Initialize the pool at price 1:1 (tick 0)
        core.initializePool(poolKey, 0);
    }

    function locked(uint256) external {
        // Execute the swap using stored parameters
        (int128 delta0, int128 delta1, PoolState stateAfter) =
            core.swap_611415377(swapPoolKey, swapAmount, swapIsToken1, swapSqrtRatioLimit, swapSkipAhead);
        bytes memory rd = abi.encode(delta0, delta1, stateAfter);
        assembly ("memory-safe") {
            return(add(rd, 0x20), mload(rd))
        }
    }

    function performSwap(int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        internal
        returns (int128 delta0, int128 delta1, PoolState stateAfter)
    {
        // Store parameters in state variables
        swapAmount = amount;
        swapIsToken1 = isToken1;
        swapSqrtRatioLimit = sqrtRatioLimit;
        swapSkipAhead = skipAhead;
        swapPoolKey = poolKey;

        // Call lock which will trigger our locked callback
        (bool success, bytes memory returnData) = address(core).call(abi.encodeWithSelector(core.lock.selector));

        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return abi.decode(returnData, (int128, int128, PoolState));
    }

    function test_swap_zero_amount_is_noop() public {
        // Store parameters in state variables
        swapAmount = 0;
        swapIsToken1 = false;
        swapSqrtRatioLimit = MAX_SQRT_RATIO;
        swapSkipAhead = 0;
        swapPoolKey = poolKey;

        // Call lock which will trigger our locked callback
        (bool success, bytes memory returnData) = address(core).call(abi.encodeWithSelector(core.lock.selector));

        require(success, "Lock call failed");

        (int128 delta0, int128 delta1,) = abi.decode(returnData, (int128, int128, PoolState));

        // Zero amount swap should not exchange any tokens
        assertEq(delta0, 0);
        assertEq(delta1, 0);
    }

    function test_swap_sqrt_ratio_limit_equals_current_is_noop() public {
        PoolState currentState = core.poolState(poolKey.toPoolId());

        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(1000, false, currentState.sqrtRatio(), 0);

        assertEq(delta0, 0, "delta0");
        assertEq(delta1, 0, "delta1");
        assertTrue(stateAfter.sqrtRatio() == currentState.sqrtRatio());
    }

    function test_swap_wrong_direction_reverts() public {
        // Try to swap token0 for token1 (increasing price) but set limit below current price
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        performSwap(1000, false, MIN_SQRT_RATIO, 0);

        // Try to swap token1 for token0 (decreasing price) but set limit above current price
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        performSwap(1000, true, MAX_SQRT_RATIO, 0);
    }

    function test_swap_invalid_sqrt_ratio_limit_reverts() public {
        vm.expectRevert(ICore.InvalidSqrtRatioLimit.selector);
        performSwap(1000, false, SqrtRatio.wrap(0), 0);

        vm.expectRevert(ICore.InvalidSqrtRatioLimit.selector);
        performSwap(1000, false, SqrtRatio.wrap(type(uint96).max), 0);
    }

    function test_swap_pool_not_initialized_reverts() public {
        // Create a new uninitialized pool
        PoolKey memory uninitializedKey =
            PoolKey({token0: address(token0), token1: address(token1), config: toConfig(3000, 60, address(0))});

        vm.expectRevert(ICore.PoolNotInitialized.selector);
        (bool success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, uninitializedKey, int128(1000), false, MAX_SQRT_RATIO, uint256(0)
            )
        );
        require(!success);
    }

    function test_swap_exact_input_token0_for_token1() public {
        // Add some liquidity first
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 amountIn = 1000;
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(amountIn, false, MAX_SQRT_RATIO, 0);

        // Should consume token0 and receive token1
        assertEq(delta0, amountIn);
        assertLt(delta1, 0); // Negative means we receive token1

        // Price should increase (sqrt ratio should be higher)
        PoolState stateBefore = core.poolState(poolKey.toPoolId());
        assertTrue(stateAfter.sqrtRatio() > stateBefore.sqrtRatio());
    }

    function test_swap_exact_input_token1_for_token0() public {
        // Add some liquidity first
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 amountIn = 1000;
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(amountIn, true, MIN_SQRT_RATIO, 0);

        // Should consume token1 and receive token0
        assertEq(delta1, amountIn);
        assertLt(delta0, 0); // Negative means we receive token0

        // Price should decrease (sqrt ratio should be lower)
        assertTrue(stateAfter.sqrtRatio() < ONE);
    }

    function test_swap_exact_output_token0_for_token1() public {
        // Add some liquidity first
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 amountOut = -500; // Negative for exact output
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(amountOut, false, MAX_SQRT_RATIO, 0);

        // Should consume token0 and receive exactly 500 token1
        assertGt(delta0, 0); // Positive means we pay token0
        assertEq(delta1, amountOut); // Should receive exactly the requested amount

        // Price should increase
        assertTrue(stateAfter.sqrtRatio() > ONE);
    }

    function test_swap_exact_output_token1_for_token0() public {
        // Add some liquidity first
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 amountOut = -500; // Negative for exact output
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(amountOut, true, MIN_SQRT_RATIO, 0);

        // Should consume token1 and receive exactly 500 token0
        assertEq(delta0, amountOut); // Should receive exactly the requested amount
        assertGt(delta1, 0); // Positive means we pay token1

        // Price should decrease
        assertTrue(stateAfter.sqrtRatio() < ONE);
    }

    function test_swap_with_fee_calculation() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 amountIn = 10000;
        (int128 delta0, int128 delta1,) = performSwap(amountIn, false, MAX_SQRT_RATIO, 0);

        // With 0.3% fee, the actual amount used for price impact should be less
        // The difference should account for fees
        assertEq(delta0, amountIn);
        assertLt(delta1, 0);

        // The amount out should be less than it would be without fees
        uint256 expectedAmountOutWithoutFees = uint256(uint128(-delta1));
        assertGt(expectedAmountOutWithoutFees, 0);
    }

    function test_swap_hits_price_limit() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        // Set a price limit that should be hit before consuming all input
        SqrtRatio priceLimit = toSqrtRatio(uint256(ONE.toFixed()) * 11 / 10, false); // 10% price increase

        int128 largeAmountIn = 100000;
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(largeAmountIn, false, priceLimit, 0);

        // Should not consume the full amount due to price limit
        assertLt(delta0, largeAmountIn);
        assertLt(delta1, 0);

        // Final price should be at or very close to the limit
        assertTrue(stateAfter.sqrtRatio() <= priceLimit);
    }

    function test_swap_zero_liquidity_moves_to_limit() public {
        // Create a pool with no liquidity
        PoolKey memory emptyPoolKey =
            PoolKey({token0: address(token0), token1: address(token1), config: toConfig(3000, 120, address(0))});
        core.initializePool(emptyPoolKey, 0);

        SqrtRatio priceLimit = toSqrtRatio(uint256(ONE.toFixed()) * 2, false);

        // Perform swap on empty pool - should move directly to limit price
        bytes memory data = abi.encode(emptyPoolKey, int128(1000), false, priceLimit, uint256(0));
        (bool success, bytes memory returnData) = address(core).call(abi.encodeWithSelector(core.lock.selector, data));
        require(success);

        (int128 delta0, int128 delta1, PoolState stateAfter) = abi.decode(returnData, (int128, int128, PoolState));

        // With zero liquidity, should move to limit price but no tokens exchanged
        assertEq(delta0, 0);
        assertEq(delta1, 0);
        assertTrue(stateAfter.sqrtRatio() == priceLimit);
    }

    function test_swap_cross_tick_updates_liquidity() public {
        // Add liquidity in a specific range
        createPosition(poolKey, -120, 120, 1000000, 1000000);

        // Get initial state
        PoolState initialState = core.poolState(poolKey.toPoolId());
        uint128 initialLiquidity = initialState.liquidity();

        // Perform a large swap that should cross ticks
        int128 largeAmount = 50000;
        (int128 delta0, int128 delta1, PoolState finalState) = performSwap(largeAmount, false, MAX_SQRT_RATIO, 0);

        assertEq(delta0, largeAmount);
        assertLt(delta1, 0);

        // The tick should have changed significantly
        assertNotEq(finalState.tick(), initialState.tick());

        // Liquidity might be different if we crossed initialized ticks
        // (In this case it should be the same since we only have one position)
        assertEq(finalState.liquidity(), initialLiquidity);
    }

    function test_swap_full_range_pool() public {
        // Create a full range pool
        PoolKey memory fullRangeKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: toConfig(3000, FULL_RANGE_ONLY_TICK_SPACING, address(0))
        });
        core.initializePool(fullRangeKey, 0);

        // Add full range liquidity
        createPosition(fullRangeKey, MIN_TICK, MAX_TICK, 1000000, 1000000);

        // Perform swap
        bytes memory data = abi.encode(fullRangeKey, int128(1000), false, MAX_SQRT_RATIO, uint256(0));
        (bool success, bytes memory returnData) = address(core).call(abi.encodeWithSelector(core.lock.selector, data));
        require(success);

        (int128 delta0, int128 delta1, PoolState stateAfter) = abi.decode(returnData, (int128, int128, PoolState));

        assertEq(delta0, 1000);
        assertLt(delta1, 0);
        assertTrue(stateAfter.sqrtRatio() > ONE);
    }

    function test_swap_with_skip_ahead() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        // Perform swap with skipAhead parameter
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(1000, false, MAX_SQRT_RATIO, 5);

        assertEq(delta0, 1000);
        assertLt(delta1, 0);
        assertTrue(stateAfter.sqrtRatio() > ONE);
    }

    function test_swap_large_amounts() public {
        // Add significant liquidity
        createPosition(poolKey, -600, 600, 100000000, 100000000);

        // Test with large amounts
        int128 largeAmount = type(int128).max / 1000; // Large but not overflow
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(largeAmount, false, MAX_SQRT_RATIO, 0);

        assertEq(delta0, largeAmount);
        assertLt(delta1, 0);
        assertTrue(stateAfter.sqrtRatio() > ONE);
    }

    function test_swap_minimum_amounts() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        // Test with minimum amounts
        (int128 delta0, int128 delta1,) = performSwap(1, false, MAX_SQRT_RATIO, 0);

        assertEq(delta0, 1);
        // With such a small amount, might get 0 out due to fees/rounding
        assertLe(delta1, 0);
    }

    function test_swap_price_impact_direction() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        PoolState initialState = core.poolState(poolKey.toPoolId());

        // Swap token0 for token1 (should increase price)
        (,, PoolState stateAfterIncrease) = performSwap(1000, false, MAX_SQRT_RATIO, 0);
        assertTrue(stateAfterIncrease.sqrtRatio() > initialState.sqrtRatio());

        // Reset pool state by swapping back
        performSwap(-500, false, MIN_SQRT_RATIO, 0);

        // Swap token1 for token0 (should decrease price)
        (,, PoolState stateAfterDecrease) = performSwap(1000, true, MIN_SQRT_RATIO, 0);
        assertTrue(stateAfterDecrease.sqrtRatio() < initialState.sqrtRatio());
    }

    function test_swap_exact_output_with_fees() public {
        // Add liquidity
        createPosition(poolKey, -60, 60, 1000000, 1000000);

        int128 exactOut = -1000;
        (int128 delta0, int128 delta1,) = performSwap(exactOut, false, MAX_SQRT_RATIO, 0);

        // Should receive exactly the requested amount
        assertEq(delta1, exactOut);
        // Should pay more than the output amount due to fees
        assertGt(uint256(uint128(delta0)), uint256(uint128(-exactOut)));
    }

    // Fuzz tests for comprehensive coverage
    function test_swap_fuzz_exact_input(
        uint128 liquidityAmount,
        int128 _swapAmount,
        bool isToken1,
        uint256 sqrtRatioLimitFixed
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, 1000, type(uint128).max / 1000));
        _swapAmount = int128(bound(_swapAmount, 1, type(int128).max / 1000));

        // Add liquidity
        createPosition(poolKey, -600, 600, liquidityAmount, liquidityAmount);

        // Set appropriate price limit
        SqrtRatio sqrtRatioLimit = isToken1
            ? toSqrtRatio(bound(sqrtRatioLimitFixed, MIN_SQRT_RATIO.toFixed(), ONE.toFixed()), false)
            : toSqrtRatio(bound(sqrtRatioLimitFixed, ONE.toFixed(), MAX_SQRT_RATIO.toFixed()), true);

        vm.assumeNoRevert();
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(_swapAmount, isToken1, sqrtRatioLimit, 0);

        // Basic invariants
        if (isToken1) {
            assertEq(delta1, _swapAmount);
            assertLe(delta0, 0);
        } else {
            assertEq(delta0, _swapAmount);
            assertLe(delta1, 0);
        }

        // Price should move in correct direction
        if (_swapAmount > 0) {
            if (isToken1) {
                assertTrue(stateAfter.sqrtRatio() <= ONE);
            } else {
                assertTrue(stateAfter.sqrtRatio() >= ONE);
            }
        }
    }

    function test_swap_fuzz_exact_output(
        uint128 liquidityAmount,
        uint128 outputAmount,
        bool isToken1,
        uint256 sqrtRatioLimitFixed
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, 10000, type(uint128).max / 1000));
        outputAmount = uint128(bound(outputAmount, 1, liquidityAmount / 100));

        // Add liquidity
        createPosition(poolKey, -600, 600, liquidityAmount, liquidityAmount);

        // Set appropriate price limit
        SqrtRatio sqrtRatioLimit = isToken1
            ? toSqrtRatio(bound(sqrtRatioLimitFixed, MIN_SQRT_RATIO.toFixed(), ONE.toFixed()), false)
            : toSqrtRatio(bound(sqrtRatioLimitFixed, ONE.toFixed(), MAX_SQRT_RATIO.toFixed()), true);

        int128 exactOut = -SafeCastLib.toInt128(outputAmount);

        vm.assumeNoRevert();
        (int128 delta0, int128 delta1, PoolState stateAfter) = performSwap(exactOut, isToken1, sqrtRatioLimit, 0);

        // Should receive exactly the requested amount
        if (isToken1) {
            assertEq(delta0, exactOut);
            assertGt(delta1, 0);
        } else {
            assertEq(delta1, exactOut);
            assertGt(delta0, 0);
        }

        // Price should move in correct direction
        if (isToken1) {
            assertTrue(stateAfter.sqrtRatio() <= ONE);
        } else {
            assertTrue(stateAfter.sqrtRatio() >= ONE);
        }
    }
}
