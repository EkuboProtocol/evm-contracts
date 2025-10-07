// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    PoolConfig,
    createStableswapPoolConfig,
    isStableswap,
    stableswapCenterTick,
    stableswapAmplification,
    createPoolConfig
} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK, STABLESWAP_POOL_TYPE_FLAG} from "../../src/math/constants.sol";

contract StableswapTest is Test {
    function test_createStableswapPoolConfig() public {
        int32 centerTick = 0;
        uint8 amplification = 3;
        uint64 fee = 1000;
        address extension = address(0x1234);

        PoolConfig config = createStableswapPoolConfig(fee, centerTick, amplification, extension);

        assertTrue(config.isStableswap());
        assertEq(config.stableswapCenterTick(), centerTick);
        assertEq(config.stableswapAmplification(), amplification);
        assertEq(config.fee(), fee);
        assertEq(config.extension(), extension);
    }

    function test_stableswapCenterTick_positive() public {
        int32 centerTick = 1000000;
        PoolConfig config = createStableswapPoolConfig(0, centerTick, 0, address(0));

        assertEq(config.stableswapCenterTick(), centerTick);
    }

    function test_stableswapCenterTick_negative() public {
        int32 centerTick = -1000000;
        PoolConfig config = createStableswapPoolConfig(0, centerTick, 0, address(0));

        assertEq(config.stableswapCenterTick(), centerTick);
    }

    function test_stableswapCenterTick_maxTick() public {
        PoolConfig config = createStableswapPoolConfig(0, MAX_TICK, 0, address(0));

        assertEq(config.stableswapCenterTick(), MAX_TICK);
    }

    function test_stableswapCenterTick_minTick() public {
        PoolConfig config = createStableswapPoolConfig(0, MIN_TICK, 0, address(0));

        assertEq(config.stableswapCenterTick(), MIN_TICK);
    }

    function test_stableswapAmplification_all_values() public {
        for (uint8 amp = 0; amp <= 7; amp++) {
            PoolConfig config = createStableswapPoolConfig(0, 0, amp, address(0));
            assertEq(config.stableswapAmplification(), amp);
        }
    }

    function test_regularPool_isNotStableswap() public {
        PoolConfig config = createPoolConfig(1000, 100, address(0x1234));

        assertFalse(config.isStableswap());
    }

    function test_stableswapFlag_set() public {
        PoolConfig config = createStableswapPoolConfig(0, 0, 0, address(0));

        uint32 tickSpacing = config.tickSpacing();
        assertEq(tickSpacing & STABLESWAP_POOL_TYPE_FLAG, STABLESWAP_POOL_TYPE_FLAG);
    }

    function test_fuzz_stableswapEncoding(int32 centerTick, uint8 amplification, uint64 fee, address extension)
        public
    {
        // Bound inputs to valid ranges
        centerTick = int32(bound(int256(centerTick), int256(MIN_TICK), int256(MAX_TICK)));
        amplification = uint8(bound(amplification, 0, 7));

        PoolConfig config = createStableswapPoolConfig(fee, centerTick, amplification, extension);

        assertTrue(config.isStableswap());
        assertEq(config.stableswapCenterTick(), centerTick);
        assertEq(config.stableswapAmplification(), amplification);
        assertEq(config.fee(), fee);
        assertEq(config.extension(), extension);
    }

    function test_tradingRange_centered() public {
        PoolConfig config = createStableswapPoolConfig(0, 0, 2, address(0));
        (int32 minTick, int32 maxTick) = config.stableswapTradingRange();

        // With center at 0 and amp=2, range should be symmetric
        assertEq(minTick, -maxTick);

        // Range should be MAX_TICK >> 2
        int32 expectedHalfRange = int32(uint32(MAX_TICK) >> 2);
        assertEq(minTick, -expectedHalfRange);
        assertEq(maxTick, expectedHalfRange);
    }

    function test_tradingRange_offCenter() public {
        int32 centerTick = 10000000;
        PoolConfig config = createStableswapPoolConfig(0, centerTick, 3, address(0));
        (int32 minTick, int32 maxTick) = config.stableswapTradingRange();

        // Range should be centered around centerTick
        int32 halfRange = int32(uint32(MAX_TICK) >> 3);
        assertEq(minTick, centerTick - halfRange);
        assertEq(maxTick, centerTick + halfRange);
    }

    function test_tradingRange_clampedToMinMax() public {
        // Test with center near MAX_TICK
        PoolConfig config1 = createStableswapPoolConfig(0, MAX_TICK - 1000, 0, address(0));
        (int32 min1, int32 max1) = config1.stableswapTradingRange();

        // Max should be clamped to MAX_TICK
        assertEq(max1, MAX_TICK);

        // Test with center near MIN_TICK
        PoolConfig config2 = createStableswapPoolConfig(0, MIN_TICK + 1000, 0, address(0));
        (int32 min2, int32 max2) = config2.stableswapTradingRange();

        // Min should be clamped to MIN_TICK
        assertEq(min2, MIN_TICK);
    }
}
