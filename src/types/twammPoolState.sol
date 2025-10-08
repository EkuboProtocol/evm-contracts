// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type TwammPoolState is bytes32;

using {
    lastVirtualOrderExecutionTime,
    realLastVirtualOrderExecutionTime,
    saleRateToken0,
    saleRateToken1,
    parse
} for TwammPoolState global;

/// @notice Extracts the last virtual order execution time from TWAMM pool state
/// @param state The TWAMM pool state
/// @return time The last virtual order execution time value, bounded by uint32
function lastVirtualOrderExecutionTime(TwammPoolState state) pure returns (uint256 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

function realLastVirtualOrderExecutionTime(TwammPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

/// @notice Extracts the sale rate for token0 from TWAMM pool state
/// @param state The TWAMM pool state
/// @return rate The sale rate for token0 value, bounded by uint112
function saleRateToken0(TwammPoolState state) pure returns (uint256 rate) {
    assembly ("memory-safe") {
        rate := shr(144, shl(112, state))
    }
}

/// @notice Extracts the sale rate for token1 from TWAMM pool state
/// @param state The TWAMM pool state
/// @return rate The sale rate for token1 value, bounded by uint112
function saleRateToken1(TwammPoolState state) pure returns (uint256 rate) {
    assembly ("memory-safe") {
        rate := shr(144, state)
    }
}

/// @notice Parses all components from TWAMM pool state
/// @param state The TWAMM pool state
/// @return time The last virtual order execution time value, bounded by uint32
/// @return rate0 The sale rate for token0 value, bounded by uint112
/// @return rate1 The sale rate for token1 value, bounded by uint112
function parse(TwammPoolState state) pure returns (uint256 time, uint256 rate0, uint256 rate1) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate0 := shr(144, shl(112, state))
        rate1 := shr(144, state)
    }
}

function createTwammPoolState(uint32 _lastVirtualOrderExecutionTime, uint112 _saleRateToken0, uint112 _saleRateToken1)
    pure
    returns (TwammPoolState s)
{
    assembly ("memory-safe") {
        // s = (lastVirtualOrderExecutionTime) | (saleRateToken0 << 32) | (saleRateToken1 << 144)
        s :=
            or(
                or(and(_lastVirtualOrderExecutionTime, 0xffffffff), shl(32, shr(144, shl(144, _saleRateToken0)))),
                shl(144, shr(144, shl(144, _saleRateToken1)))
            )
    }
}
