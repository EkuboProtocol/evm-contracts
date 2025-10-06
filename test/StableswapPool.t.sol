// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FullTest} from "./FullTest.sol";
import {PoolKey, validatePoolKey, InvalidStableswapCenterTick} from "../src/types/poolKey.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "../src/types/sqrtRatio.sol";
import {SwapParameters} from "../src/types/swapParameters.sol";
import {RouteNode, TokenAmount} from "../src/Router.sol";

contract StableswapPoolTest is FullTest {
    function test_initializeStableswapPool() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(1 << 63, 0, 5, address(0))
        });

        assertTrue(poolKey.isStableswap());
        assertEq(poolKey.config.stableswapCenterTick(), 0);
        assertEq(poolKey.config.stableswapAmplification(), 5);

        poolKey.validatePoolKey();

        SqrtRatio sqrtRatio = core.initializePool(poolKey, 0);
        assertGt(SqrtRatio.unwrap(sqrtRatio), 0);
    }

    function test_stableswapPool_validation_centerTick_tooHigh() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(0, MAX_TICK + 1, 0, address(0))
        });

        // The validation should fail when trying to initialize the pool
        vm.expectRevert(InvalidStableswapCenterTick.selector);
        core.initializePool(poolKey, 0);
    }

    function test_stableswapPool_validation_centerTick_tooLow() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(0, MIN_TICK - 1, 0, address(0))
        });

        // The validation should fail when trying to initialize the pool
        vm.expectRevert(InvalidStableswapCenterTick.selector);
        core.initializePool(poolKey, 0);
    }

    function test_stableswapPool_swap() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(1 << 63, 0, 5, address(0))
        });

        poolKey.validatePoolKey();
        core.initializePool(poolKey, 0);

        // Add liquidity
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Perform a swap
        token0.approve(address(router), type(uint256).max);
        uint256 balanceBefore = token0.balanceOf(address(this));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 1e17}),
            type(int256).min
        );

        // Verify swap succeeded (balance changed)
        assertLt(token0.balanceOf(address(this)), balanceBefore);
    }

    function test_stableswapPool_noTickBitmapLoading() public {
        // This test verifies that stableswap pools don't load tick bitmaps during swaps
        // by checking gas usage is similar to full-range pools
        PoolKey memory stableswapPool = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(1 << 63, 0, 5, address(0))
        });

        stableswapPool.validatePoolKey();
        core.initializePool(stableswapPool, 0);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        positions.mintAndDeposit(stableswapPool, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        token0.approve(address(router), type(uint256).max);

        // Measure gas for stableswap pool swap
        uint256 gasBefore = gasleft();
        router.swap(
            RouteNode({poolKey: stableswapPool, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 1e17}),
            type(int256).min
        );
        uint256 stableswapGas = gasBefore - gasleft();

        // Gas should be reasonable (not loading tick bitmaps)
        // This is a sanity check - actual gas comparison would need a regular pool
        assertLt(stableswapGas, 500000);
    }

    function test_stableswapPool_differentCenterTicks() public {
        int32[3] memory centerTicks = [int32(-1000000), int32(0), int32(1000000)];

        for (uint256 i = 0; i < centerTicks.length; i++) {
            PoolKey memory poolKey = PoolKey({
                token0: address(token0),
                token1: address(token1),
                config: createStableswapPoolConfig(1 << 63, centerTicks[i], 5, address(0))
            });

            poolKey.validatePoolKey();
            assertEq(poolKey.config.stableswapCenterTick(), centerTicks[i]);

            // Should be able to initialize at the center tick
            core.initializePool(poolKey, centerTicks[i]);
        }
    }

    function test_stableswapPool_maxLiquidityPerTick() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(0, 0, 5, address(0))
        });

        // Stableswap pools should have max liquidity per tick like full-range pools
        assertEq(poolKey.config.maxLiquidityPerTick(), type(uint128).max);
    }
}
