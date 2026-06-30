// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";

type VePoolVote is bytes32;

using {weight, swapFee, timestamp, parse, fees} for VePoolVote global;

/// @notice Returns the active vote weight.
function weight(VePoolVote vote) pure returns (uint128 value) {
    assembly ("memory-safe") {
        value := vote
    }
}

/// @notice Returns the fee selected by the stake for this pool.
function swapFee(VePoolVote vote) pure returns (uint64 value) {
    assembly ("memory-safe") {
        value := shr(128, vote)
    }
}

/// @notice Returns the timestamp when this vote accounting was last written.
function timestamp(VePoolVote vote) pure returns (uint64 value) {
    assembly ("memory-safe") {
        value := shr(192, vote)
    }
}

/// @notice Returns all fields in the packed vote.
function parse(VePoolVote vote) pure returns (uint128 weight_, uint64 swapFee_, uint64 timestamp_) {
    assembly ("memory-safe") {
        weight_ := vote
        swapFee_ := shr(128, vote)
        timestamp_ := shr(192, vote)
    }
}

/// @notice Creates a packed ve pool vote.
function createVePoolVote(uint128 weight_, uint64 swapFee_, uint64 timestamp_) pure returns (VePoolVote vote) {
    assembly ("memory-safe") {
        vote := or(
            or(and(weight_, 0xffffffffffffffffffffffffffffffff), shl(128, and(swapFee_, 0xffffffffffffffff))),
            shl(192, and(timestamp_, 0xffffffffffffffff))
        )
    }
}

/// @notice Calculates the fees owed to a ve pool vote.
/// @param vote The ve pool vote to calculate fees for.
/// @param feeGrowth Current pool fee growth per unit of vote weight.
/// @param feeGrowthSnapshot Vote's last pool fee-growth snapshot.
/// @return amount0 Amount of token0 fees owed.
/// @return amount1 Amount of token1 fees owed.
function fees(VePoolVote vote, FeesPerLiquidity memory feeGrowth, FeesPerLiquidity memory feeGrowthSnapshot)
    pure
    returns (uint128 amount0, uint128 amount1)
{
    uint128 weight_ = vote.weight();
    FeesPerLiquidity memory feeGrowthDelta = feeGrowth.sub(feeGrowthSnapshot);
    amount0 = uint128(FixedPointMathLib.fullMulDivN(feeGrowthDelta.value0, weight_, 128));
    amount1 = uint128(FixedPointMathLib.fullMulDivN(feeGrowthDelta.value1, weight_, 128));
}
