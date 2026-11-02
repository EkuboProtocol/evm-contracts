// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    PoolConfig,
    createFullRangePoolConfig,
    createConcentratedPoolConfig,
    createStableswapPoolConfig
} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING_EXP} from "../../src/math/constants.sol";

contract PoolConfigTest is Test {
    function test_conversionToAndFrom_concentrated(PoolConfig config) public pure {
        // Only concentrated pools round-trip; clear the reserved bits first since construction zeroes them
        uint256 raw = uint256(PoolConfig.unwrap(config));
        // clear the reserved low bits first since construction zeroes them
        raw &= ~uint256(0x7fffff);
        vm.assume(PoolConfig.wrap(bytes32(raw)).isConcentrated());
        vm.assume(PoolConfig.wrap(bytes32(raw)).tickSpacingExp() <= MAX_TICK_SPACING_EXP);
        config = PoolConfig.wrap(bytes32(raw));
        assertEq(
            PoolConfig.unwrap(
                createConcentratedPoolConfig({
                    _fee: config.fee(),
                    _tickSpacingExp: config.tickSpacingExp(),
                    _extension: config.extension(),
                    _salt: config.salt()
                })
            ),
            PoolConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(uint16 fee, uint8 tickSpacingExp, address extension, uint64 salt) public pure {
        tickSpacingExp = uint8(bound(tickSpacingExp, 0, MAX_TICK_SPACING_EXP));
        salt = salt & 0xffffffffffff;

        PoolConfig config = createConcentratedPoolConfig({
            _fee: fee, _tickSpacingExp: tickSpacingExp, _extension: extension, _salt: salt
        });
        assertEq(config.fee(), fee);
        assertEq(config.tickSpacingExp(), tickSpacingExp);
        assertEq(config.concentratedTickSpacing(), uint32(uint256(1) << tickSpacingExp));
        assertEq(config.salt(), salt);
        assertEq(config.extension(), extension);
        assertTrue(config.isConcentrated(), "should be concentrated");
        assertFalse(config.isFullRange(), "concentrated pools are not full range");
    }

    function test_createFullRangePoolConfig(uint16 fee, address extension, uint64 salt) public pure {
        salt = salt & 0xffffffffffff;
        PoolConfig config = createFullRangePoolConfig(fee, extension, salt);
        assertEq(config.fee(), fee);
        assertEq(config.salt(), salt);
        assertEq(config.concentratedTickSpacing(), 1);
        assertEq(config.stableswapAmplification(), 0);
        assertEq(config.stableswapCenterTick(), 0);
        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        assertEq(lower, MIN_TICK);
        assertEq(upper, MAX_TICK);
        assertEq(config.extension(), extension);
        assertTrue(config.isFullRange(), "isFullRange");
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 feeDirty,
        bytes32 expDirty,
        bytes32 saltDirty,
        bytes32 extensionDirty
    ) public pure {
        uint16 fee;
        uint8 tickSpacingExp;
        uint64 salt;
        address extension;

        assembly ("memory-safe") {
            fee := feeDirty
            tickSpacingExp := expDirty
            salt := saltDirty
            extension := extensionDirty
        }

        uint16 expectedFee = fee & 0xffff;
        uint8 expectedExp = tickSpacingExp & 0xff;
        uint64 expectedSalt = salt & 0xffffffffffff;

        PoolConfig config = createConcentratedPoolConfig({
            _fee: fee, _tickSpacingExp: tickSpacingExp, _extension: extension, _salt: salt
        });
        assertEq(config.fee(), expectedFee, "fee");
        assertEq(config.tickSpacingExp(), expectedExp, "tickSpacingExp");
        assertEq(config.salt(), expectedSalt, "salt");
        assertEq(config.extension(), extension, "extension");
    }

    function test_stableswapPoolConfig(
        uint16 fee,
        uint8 stableswapAmplification,
        int32 stableswapCenterTick,
        address extension,
        uint64 salt
    ) public pure {
        // Limit amplification to valid range
        stableswapAmplification = uint8(bound(stableswapAmplification, 0, 26));
        // Limit center tick to representable range (24 bits signed, scaled by 16)
        stableswapCenterTick = int32(bound(stableswapCenterTick, MIN_TICK, MAX_TICK));
        salt = salt & 0xffffffffffff;

        PoolConfig config = createStableswapPoolConfig({
            _fee: fee,
            _amplification: stableswapAmplification,
            _centerTick: stableswapCenterTick,
            _extension: extension,
            _salt: salt
        });

        assertEq(config.fee(), fee, "fee");
        assertEq(config.salt(), salt, "salt");
        assertEq(config.stableswapAmplification(), stableswapAmplification, "stableswapAmplification");
        assertEq(config.stableswapCenterTick(), (stableswapCenterTick / 16) * 16, "stableswapCenterTick");

        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        assertGe(lower, MIN_TICK, "lower");
        assertLe(upper, MAX_TICK, "upper");
        assertGt(upper, lower, "upper>lower");

        assertEq(config.extension(), extension, "extension");
        assertTrue(config.isStableswap(), "should be stableswap");
        assertEq(
            config.isFullRange(),
            config.stableswapAmplification() == 0 && config.stableswapCenterTick() == 0,
            "should be full range only if amp and center tick is 0"
        );
        assertFalse(config.isConcentrated(), "should not be concentrated");
    }

    function test_concentratedMaxLiquidityPerTick(uint16 fee, uint8 tickSpacingExp, address extension) public pure {
        tickSpacingExp = uint8(bound(tickSpacingExp, 0, MAX_TICK_SPACING_EXP));
        PoolConfig config =
            createConcentratedPoolConfig({_fee: fee, _tickSpacingExp: tickSpacingExp, _extension: extension, _salt: 0});
        config.validate();

        uint32 tickSpacing = uint32(uint256(1) << tickSpacingExp);
        assertEq(config.concentratedTickSpacing(), tickSpacing);

        int256 ts = int256(uint256(tickSpacing));

        uint256 maxLiquidity = config.concentratedMaxLiquidityPerTick();

        if (ts > MAX_TICK) {
            assertEq(maxLiquidity, type(uint128).max);
        } else {
            uint256 numTicks = uint256(1 + ((MAX_TICK / ts) * 2));
            assertLe(maxLiquidity * numTicks, type(uint128).max);
        }
    }
}
