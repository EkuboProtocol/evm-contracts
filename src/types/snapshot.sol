// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type Snapshot is bytes32;

using {timestamp, secondsPerLiquidityCumulative, tickCumulative} for Snapshot global;

/// @notice Extracts the timestamp from a snapshot
/// @param snapshot The snapshot
/// @return t The timestamp value, bounded by uint32
function timestamp(Snapshot snapshot) pure returns (uint256 t) {
    assembly ("memory-safe") {
        t := and(snapshot, 0xFFFFFFFF)
    }
}

/// @notice Extracts the seconds per liquidity cumulative from a snapshot
/// @param snapshot The snapshot
/// @return s The seconds per liquidity cumulative value, bounded by uint160
function secondsPerLiquidityCumulative(Snapshot snapshot) pure returns (uint256 s) {
    assembly ("memory-safe") {
        s := and(shr(32, snapshot), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
    }
}

/// @notice Extracts the tick cumulative from a snapshot
/// @param snapshot The snapshot
/// @return t The tick cumulative value, bounded by int64
function tickCumulative(Snapshot snapshot) pure returns (int256 t) {
    assembly ("memory-safe") {
        t := signextend(7, shr(192, snapshot))
    }
}

function createSnapshot(uint32 _timestamp, uint160 _secondsPerLiquidityCumulative, int64 _tickCumulative)
    pure
    returns (Snapshot s)
{
    assembly ("memory-safe") {
        // s = timestamp | (secondsPerLiquidityCumulative << 32) | (tickCumulative << 192)
        s :=
            or(
                or(
                    and(_timestamp, 0xFFFFFFFF),
                    shl(32, and(_secondsPerLiquidityCumulative, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
                ),
                shl(192, and(_tickCumulative, 0xFFFFFFFFFFFFFFFF))
            )
    }
}
