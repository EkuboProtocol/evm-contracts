// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {MAX_TICK} from "../../src/math/constants.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {
    MAX_VE_FEE,
    capFee,
    defaultFeeForStableswapAmplification,
    defaultFeeForTickSpacing
} from "../../src/math/tickSpacingFee.sol";

contract TickSpacingFeeTest is Test {
    uint32 constant CAP_TICK_SPACING = 346574;

    function referenceDefaultFeeForTickSpacing(uint32 tickSpacing) internal pure returns (uint64 fee) {
        unchecked {
            uint256 tick = uint256(tickSpacing) * 2;
            if (tick >= 693147) return MAX_VE_FEE;

            uint256 sqrtRatioFixed = tickToSqrtRatio(int32(uint32(tick))).toFixed();
            uint256 priceX128 = FixedPointMathLib.fullMulDivN(sqrtRatioFixed, sqrtRatioFixed, 128);
            uint256 feeX64 = ((priceX128 - (1 << 128)) << 64) / priceX128;

            fee = uint64(FixedPointMathLib.min(feeX64, MAX_VE_FEE));
        }
    }

    function test_defaultFeeForTickSpacing_examples() public pure {
        assertEq(defaultFeeForTickSpacing(0), 0);
        assertEq(defaultFeeForTickSpacing(1), 36893432807257);
        assertEq(defaultFeeForTickSpacing(100), referenceDefaultFeeForTickSpacing(100));
        assertEq(
            defaultFeeForTickSpacing(CAP_TICK_SPACING - 1), referenceDefaultFeeForTickSpacing(CAP_TICK_SPACING - 1)
        );
        assertEq(defaultFeeForTickSpacing(CAP_TICK_SPACING), MAX_VE_FEE);
    }

    function test_defaultFeeForTickSpacing_matchesReference(uint32 tickSpacing) public pure {
        assertEq(defaultFeeForTickSpacing(tickSpacing), referenceDefaultFeeForTickSpacing(tickSpacing));
    }

    function test_defaultFeeForTickSpacing_isMonotonicBeforeCap(uint32 lower, uint32 upper) public pure {
        lower = uint32(bound(lower, 0, CAP_TICK_SPACING - 1));
        upper = uint32(bound(upper, lower, CAP_TICK_SPACING - 1));

        assertLe(defaultFeeForTickSpacing(lower), defaultFeeForTickSpacing(upper));
    }

    function test_defaultFeeForTickSpacing_caps(uint32 tickSpacing) public pure {
        tickSpacing = uint32(bound(tickSpacing, CAP_TICK_SPACING, type(uint32).max));

        assertEq(defaultFeeForTickSpacing(tickSpacing), MAX_VE_FEE);
    }

    function test_defaultFeeForTickSpacing_neverExceedsCap(uint32 tickSpacing) public pure {
        assertLe(defaultFeeForTickSpacing(tickSpacing), MAX_VE_FEE);
    }

    function test_defaultFeeForStableswapAmplification_examples() public pure {
        assertEq(defaultFeeForStableswapAmplification(0), MAX_VE_FEE);
        assertEq(defaultFeeForStableswapAmplification(7), MAX_VE_FEE);
        assertEq(defaultFeeForStableswapAmplification(8), defaultFeeForTickSpacing(uint32(MAX_TICK) >> 8));
        assertEq(defaultFeeForStableswapAmplification(9), defaultFeeForTickSpacing(uint32(MAX_TICK) >> 9));
        assertEq(defaultFeeForStableswapAmplification(26), defaultFeeForTickSpacing(1));
        assertEq(defaultFeeForStableswapAmplification(27), defaultFeeForTickSpacing(1));
        assertEq(defaultFeeForStableswapAmplification(type(uint8).max), defaultFeeForTickSpacing(1));
    }

    function test_defaultFeeForStableswapAmplification_matchesTickSpacingConversion(uint8 amplification) public pure {
        uint256 tickSpacing = uint256(uint32(MAX_TICK)) >> amplification;
        if (tickSpacing == 0) tickSpacing = 1;

        assertEq(defaultFeeForStableswapAmplification(amplification), defaultFeeForTickSpacing(uint32(tickSpacing)));
    }

    function test_defaultFeeForStableswapAmplification_neverExceedsCap(uint8 amplification) public pure {
        assertLe(defaultFeeForStableswapAmplification(amplification), MAX_VE_FEE);
    }

    function test_capFee_examples() public pure {
        assertEq(capFee(0), 0);
        assertEq(capFee(MAX_VE_FEE - 1), MAX_VE_FEE - 1);
        assertEq(capFee(MAX_VE_FEE), MAX_VE_FEE);
        assertEq(capFee(MAX_VE_FEE + 1), MAX_VE_FEE);
        assertEq(capFee(type(uint64).max), MAX_VE_FEE);
    }

    function test_capFee(uint64 fee) public pure {
        uint64 capped = capFee(fee);

        assertLe(capped, MAX_VE_FEE);
        assertEq(capped, fee > MAX_VE_FEE ? MAX_VE_FEE : fee);
    }
}
