// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type Observation is bytes32;

using {secondsPerLiquidityCumulative, tickCumulative} for Observation global;

/// @notice Extracts the seconds per liquidity cumulative from an observation
/// @param observation The observation
/// @return s The seconds per liquidity cumulative value, bounded by uint160
function secondsPerLiquidityCumulative(Observation observation) pure returns (uint256 s) {
    assembly ("memory-safe") {
        s := shr(96, observation)
    }
}

/// @notice Extracts the tick cumulative from an observation
/// @param observation The observation
/// @return t The tick cumulative value, bounded by int64
function tickCumulative(Observation observation) pure returns (int256 t) {
    assembly ("memory-safe") {
        t := signextend(7, observation)
    }
}

function createObservation(uint160 _secondsPerLiquidityCumulative, int64 _tickCumulative)
    pure
    returns (Observation o)
{
    assembly ("memory-safe") {
        // o = (secondsPerLiquidityCumulative << 96) | tickCumulative
        o := or(shl(96, _secondsPerLiquidityCumulative), and(_tickCumulative, 0xFFFFFFFFFFFFFFFF))
    }
}
