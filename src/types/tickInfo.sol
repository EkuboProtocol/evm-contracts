// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type TickInfo is bytes32;

using {liquidityDelta, liquidityNet, parse} for TickInfo global;

/// @notice Extracts the liquidity delta from tick info
/// @param info The tick info
/// @return delta The liquidity delta value, bounded by int128
function liquidityDelta(TickInfo info) pure returns (int256 delta) {
    assembly ("memory-safe") {
        delta := signextend(15, info)
    }
}

/// @notice Extracts the liquidity net from tick info
/// @param info The tick info
/// @return net The liquidity net value, bounded by uint128
function liquidityNet(TickInfo info) pure returns (uint256 net) {
    assembly ("memory-safe") {
        net := shr(128, info)
    }
}

/// @notice Parses both components from tick info
/// @param info The tick info
/// @return delta The liquidity delta value, bounded by int128
/// @return net The liquidity net value, bounded by uint128
function parse(TickInfo info) pure returns (int256 delta, uint256 net) {
    assembly ("memory-safe") {
        delta := signextend(15, info)
        net := shr(128, info)
    }
}

function createTickInfo(int128 _liquidityDelta, uint128 _liquidityNet) pure returns (TickInfo info) {
    assembly ("memory-safe") {
        // info = (liquidityNet << 128) | liquidityDelta
        info := or(shl(128, _liquidityNet), shr(128, shl(128, _liquidityDelta)))
    }
}
