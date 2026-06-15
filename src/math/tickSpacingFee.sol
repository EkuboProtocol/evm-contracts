// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {MAX_TICK} from "./constants.sol";
import {tickToSqrtRatio} from "./ticks.sol";

uint64 constant MAX_VE_FEE = uint64(1 << 63);

/// @notice Converts a tick spacing to the default ve pool fee using a 2x tick-spacing move.
/// @dev Returns 1 - 1 / 1.000001^(2 * tickSpacing), capped at 50% in 0.64 fixed point.
function defaultFeeForTickSpacing(uint32 tickSpacing) pure returns (uint64 fee) {
    unchecked {
        uint256 tick = uint256(tickSpacing) * 2;
        if (tick >= 693147) return MAX_VE_FEE;

        uint256 sqrtRatioFixed = tickToSqrtRatio(int32(uint32(tick))).toFixed();
        uint256 priceX128 = FixedPointMathLib.fullMulDivN(sqrtRatioFixed, sqrtRatioFixed, 128);
        uint256 feeX64 = ((priceX128 - (1 << 128)) << 64) / priceX128;

        fee = uint64(FixedPointMathLib.min(feeX64, MAX_VE_FEE));
    }
}

/// @notice Converts a stableswap amplification to the default ve pool fee using its active range width.
function defaultFeeForStableswapAmplification(uint8 amplification) pure returns (uint64 fee) {
    unchecked {
        uint256 tickSpacing = uint256(uint32(MAX_TICK)) >> amplification;
        if (tickSpacing == 0) tickSpacing = 1;
        fee = defaultFeeForTickSpacing(uint32(tickSpacing));
    }
}

function capFee(uint64 fee) pure returns (uint64) {
    return fee > MAX_VE_FEE ? MAX_VE_FEE : fee;
}
