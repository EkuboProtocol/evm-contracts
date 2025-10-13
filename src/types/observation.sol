// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

type Observation is bytes32;

using {secondsPerLiquidityCumulative, tickCumulative} for Observation global;

function secondsPerLiquidityCumulative(Observation observation) pure returns (uint160 s) {
    assembly ("memory-safe") {
        s := shr(96, observation)
    }
}

function tickCumulative(Observation observation) pure returns (int64 t) {
    assembly ("memory-safe") {
        t := signextend(7, observation)
    }
}

function createObservation(uint160 _secondsPerLiquidityCumulative, int64 _tickCumulative) pure returns (Observation o) {
    assembly ("memory-safe") {
        // o = (secondsPerLiquidityCumulative << 96) | tickCumulative
        o := or(shl(96, _secondsPerLiquidityCumulative), and(_tickCumulative, 0xFFFFFFFFFFFFFFFF))
    }
}
