// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

type Snapshot is bytes32;

using {timestamp, secondsPerLiquidityCumulative, tickCumulative} for Snapshot global;

function timestamp(Snapshot snapshot) pure returns (uint32 t) {
    assembly ("memory-safe") {
        t := and(snapshot, 0xFFFFFFFF)
    }
}

function secondsPerLiquidityCumulative(Snapshot snapshot) pure returns (uint160 s) {
    assembly ("memory-safe") {
        s := and(shr(32, snapshot), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
    }
}

function tickCumulative(Snapshot snapshot) pure returns (int64 t) {
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
        s := or(
            or(
                and(_timestamp, 0xFFFFFFFF),
                shl(32, and(_secondsPerLiquidityCumulative, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            ),
            shl(192, and(_tickCumulative, 0xFFFFFFFFFFFFFFFF))
        )
    }
}
