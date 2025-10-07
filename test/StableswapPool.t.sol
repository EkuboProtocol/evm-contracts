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
            config: createStableswapPoolConfig(1 << 63, 0, 2, address(0))
        });

        assertTrue(poolKey.isStableswap());
        assertEq(poolKey.config.stableswapCenterTick(), 0);
        assertEq(poolKey.config.stableswapAmplification(), 2);

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

        vm.expectRevert(InvalidStableswapCenterTick.selector);
        core.initializePool(poolKey, 0);
    }

    function test_stableswapPool_validation_centerTick_tooLow() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(0, MIN_TICK - 1, 0, address(0))
        });

        vm.expectRevert(InvalidStableswapCenterTick.selector);
        core.initializePool(poolKey, 0);
    }

    function test_stableswapPool_tradingRange() public {
        // Test with amplification = 0 (no concentration, 2^0 = 1x)
        PoolConfig config0 = createStableswapPoolConfig(0, 0, 0, address(0));
        (int32 min0, int32 max0) = config0.stableswapTradingRange();
        // With amp=0, range should be full: MAX_TICK_MAGNITUDE >> 0 = MAX_TICK_MAGNITUDE
        assertEq(min0, MIN_TICK);
        assertEq(max0, MAX_TICK);

        // Test with amplification = 2 (4x concentration, 2^2 = 4x)
        PoolConfig config2 = createStableswapPoolConfig(0, 0, 2, address(0));
        (int32 min2, int32 max2) = config2.stableswapTradingRange();
        // With amp=2, range should be: MAX_TICK_MAGNITUDE >> 2 = MAX_TICK_MAGNITUDE / 4
        int32 expectedHalfRange2 = int32(uint32(MAX_TICK) >> 2);
        assertEq(min2, -expectedHalfRange2);
        assertEq(max2, expectedHalfRange2);

        // Test with amplification = 7 (128x concentration, 2^7 = 128x)
        PoolConfig config7 = createStableswapPoolConfig(0, 0, 7, address(0));
        (int32 min7, int32 max7) = config7.stableswapTradingRange();
        // With amp=7, range should be much smaller
        int32 expectedHalfRange7 = int32(uint32(MAX_TICK) >> 7);
        assertEq(min7, -expectedHalfRange7);
        assertEq(max7, expectedHalfRange7);

        // Verify range gets smaller with higher amplification
        assertTrue(max7 < max2);
        assertTrue(max2 < max0);
    }

    function test_stableswapPool_swap() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createStableswapPoolConfig(1 << 63, 0, 2, address(0))
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

    function test_stableswapPool_differentCenterTicks() public {
        int32[3] memory centerTicks = [int32(-1000000), int32(0), int32(1000000)];

        for (uint256 i = 0; i < centerTicks.length; i++) {
            PoolKey memory poolKey = PoolKey({
                token0: address(token0),
                token1: address(token1),
                config: createStableswapPoolConfig(1 << 63, centerTicks[i], 2, address(0))
            });

            poolKey.validatePoolKey();
            assertEq(poolKey.config.stableswapCenterTick(), centerTicks[i]);

            // Should be able to initialize at the center tick
            core.initializePool(poolKey, centerTicks[i]);
        }
    }

    function test_stableswapPool_amplificationLevels() public {
        // Test all amplification levels (0-7)
        for (uint8 amp = 0; amp <= 7; amp++) {
            PoolKey memory poolKey = PoolKey({
                token0: address(token0),
                token1: address(token1),
                config: createStableswapPoolConfig(1 << 63, 0, amp, address(0))
            });

            poolKey.validatePoolKey();
            assertEq(poolKey.config.stableswapAmplification(), amp);

            // Verify liquidity multiplier is 2^amp
            (int32 minTick, int32 maxTick) = poolKey.config.stableswapTradingRange();
            int32 expectedHalfRange = int32(uint32(MAX_TICK) >> amp);
            assertEq(minTick, -expectedHalfRange);
            assertEq(maxTick, expectedHalfRange);
        }
    }
}
