// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/// @notice Packed representation of time-specific order information
/// @dev Bit layout (256 bits total):
///      - bits 255-224: numOrders (uint32)
///      - bits 223-112: saleRateDeltaToken0 (int112)
///      - bits 111-0:   saleRateDeltaToken1 (int112)
type TimeInfo is bytes32;

using {numOrders, saleRateDeltaToken0, saleRateDeltaToken1, parse} for TimeInfo global;

/// @notice Extracts the number of orders from time info
/// @param info The time info
/// @return n The number of orders value, bounded by uint32
function numOrders(TimeInfo info) pure returns (uint256 n) {
    assembly ("memory-safe") {
        n := shr(224, info)
    }
}

/// @notice Extracts the sale rate delta for token0 from time info
/// @param info The time info
/// @return delta The sale rate delta for token0 value, bounded by int112
function saleRateDeltaToken0(TimeInfo info) pure returns (int256 delta) {
    assembly ("memory-safe") {
        delta := signextend(13, shr(112, info))
    }
}

/// @notice Extracts the sale rate delta for token1 from time info
/// @param info The time info
/// @return delta The sale rate delta for token1 value, bounded by int112
function saleRateDeltaToken1(TimeInfo info) pure returns (int256 delta) {
    assembly ("memory-safe") {
        delta := signextend(13, info)
    }
}

/// @notice Parses all components from time info
/// @param info The time info
/// @return n The number of orders value, bounded by uint32
/// @return delta0 The sale rate delta for token0 value, bounded by int112
/// @return delta1 The sale rate delta for token1 value, bounded by int112
function parse(TimeInfo info) pure returns (uint256 n, int256 delta0, int256 delta1) {
    assembly ("memory-safe") {
        n := shr(224, info)
        delta0 := signextend(13, shr(112, info))
        delta1 := signextend(13, info)
    }
}

function createTimeInfo(uint32 _numOrders, int112 _saleRateDeltaToken0, int112 _saleRateDeltaToken1)
    pure
    returns (TimeInfo info)
{
    assembly ("memory-safe") {
        // info = (numOrders << 224) | ((saleRateDeltaToken0 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) << 112) | (saleRateDeltaToken1 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        info :=
            or(
                shl(224, _numOrders),
                or(
                    shl(112, and(_saleRateDeltaToken0, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                    and(_saleRateDeltaToken1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                )
            )
    }
}
