// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    PoolConfig,
    createFullRangePoolConfig,
    createPoolConfig,
    createStableswapPoolConfig
} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract PoolConfigTest is Test {
    function test_conversionToAndFrom_concentrated(PoolConfig config) public pure {
        // Only test concentrated pools (bit 31 = 1)
        vm.assume(config.isConcentrated());
        assertEq(
            PoolConfig.unwrap(
                createPoolConfig({
                    _fee: config.fee(),
                    _tickSpacing: config.tickSpacing(),
                    _extension: config.extension()
                })
            ),
            PoolConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(uint64 fee, uint32 tickSpacing, address extension) public pure {
        // Mask tick spacing to 31 bits since bit 31 is used for discriminator
        tickSpacing = tickSpacing & 0x7fffffff;

        PoolConfig config = createPoolConfig({_fee: fee, _tickSpacing: tickSpacing, _extension: extension});
        assertEq(config.fee(), fee);
        assertEq(config.tickSpacing(), tickSpacing);
        assertEq(config.extension(), extension);
        assertTrue(config.isConcentrated(), "should be concentrated");
        assertFalse(config.isFullRange(), "concentrated pools are not full range");
    }

    function test_createFullRangePoolConfig(uint64 fee, address extension) public pure {
        PoolConfig config = createFullRangePoolConfig(fee, extension);
        assertEq(config.fee(), fee);
        assertEq(config.tickSpacing(), 0);
        assertEq(config.stableswapAmplificationFactor(), 0);
        assertEq(config.stableswapCenterTick(), 0);
        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        assertEq(lower, MIN_TICK);
        assertEq(upper, MAX_TICK);
        assertEq(config.extension(), extension);
        assertTrue(config.isFullRange(), "isFullRange");
    }

    function test_conversionFromAndToDirtyBits(bytes32 feeDirty, bytes32 tickSpacingDirty, bytes32 extensionDirty)
        public
        pure
    {
        uint64 fee;
        uint32 tickSpacing;
        address extension;

        assembly ("memory-safe") {
            fee := feeDirty
            tickSpacing := tickSpacingDirty
            extension := extensionDirty
        }

        // Mask tick spacing to 31 bits since bit 31 is used for discriminator
        uint32 expectedTickSpacing = tickSpacing & 0x7fffffff;

        PoolConfig config = createPoolConfig({_fee: fee, _tickSpacing: tickSpacing, _extension: extension});
        assertEq(config.fee(), fee, "fee");
        assertEq(config.tickSpacing(), expectedTickSpacing, "tickSpacing");
        assertEq(config.extension(), extension, "extension");
    }

    function test_stableswapPoolConfig(
        uint64 fee,
        uint8 stableswapAmplificationFactor,
        int32 stableswapCenterTick,
        address extension
    ) public pure {
        // Limit amplification to valid range
        stableswapAmplificationFactor = uint8(bound(stableswapAmplificationFactor, 0, 26));
        // Limit center tick to representable range (24 bits signed, scaled by 16)
        stableswapCenterTick = int32(bound(stableswapCenterTick, MIN_TICK, MAX_TICK));
        // Round to multiple of 16
        stableswapCenterTick = (stableswapCenterTick / 16) * 16;

        PoolConfig config = createStableswapPoolConfig({
            _fee: fee,
            _stableswapAmplificationFactor: stableswapAmplificationFactor,
            _stableswapCenterTick: stableswapCenterTick,
            _extension: extension
        });

        assertEq(config.fee(), fee, "fee");
        assertEq(config.stableswapAmplificationFactor(), stableswapAmplificationFactor, "stableswapAmplificationFactor");
        assertEq(config.stableswapCenterTick(), stableswapCenterTick, "stableswapCenterTick");

        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        assertGe(lower, MIN_TICK, "lower");
        assertLe(upper, MAX_TICK, "upper");
        assertGt(upper, lower, "upper>lower");

        assertEq(config.extension(), extension, "extension");
        assertTrue(config.isStableswap(), "should be stableswap");
        assertFalse(config.isConcentrated(), "should not be concentrated");
    }

    function test_maxLiquidityPerTickConcentratedLiquidity(PoolConfig config) public pure {
        vm.assume(!config.isFullRange());
        int256 tickSpacing = int256(uint256(config.tickSpacing()));

        uint256 maxLiquidity = config.maxLiquidityPerTickConcentratedLiquidity();

        if (int32(tickSpacing) > MAX_TICK) {
            assertEq(maxLiquidity, type(uint128).max);
        } else {
            uint256 numTicks = uint256(1 + ((MAX_TICK / tickSpacing) * 2));
            assertLe(maxLiquidity * numTicks, type(uint128).max);
        }
    }
}
