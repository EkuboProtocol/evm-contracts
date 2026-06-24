// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";

/// @notice Per-stake accounting for one voted pool.
/// @param weight Active vote weight from the stake to the pool.
/// @param swapFee Fee selected by the stake for this pool.
struct VePoolPosition {
    uint128 weight;
    uint64 swapFee;
}

using {fees} for VePoolPosition global;

/// @notice Calculates the fees owed to a ve pool position.
/// @param position The ve pool position to calculate fees for.
/// @param feeGrowth Current pool fee growth per unit of vote weight.
/// @param feeGrowthSnapshot Position's last pool fee-growth snapshot.
/// @return amount0 Amount of token0 fees owed.
/// @return amount1 Amount of token1 fees owed.
function fees(
    VePoolPosition memory position,
    FeesPerLiquidity memory feeGrowth,
    FeesPerLiquidity memory feeGrowthSnapshot
) pure returns (uint128 amount0, uint128 amount1) {
    uint128 weight = position.weight;
    if (weight != 0) {
        FeesPerLiquidity memory feeGrowthDelta = feeGrowth.sub(feeGrowthSnapshot);
        amount0 = uint128(FixedPointMathLib.fullMulDivN(feeGrowthDelta.value0, weight, 128));
        amount1 = uint128(FixedPointMathLib.fullMulDivN(feeGrowthDelta.value1, weight, 128));
    }
}
