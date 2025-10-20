// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

/// @notice Packed representation of time-specific order information
/// @dev Bit layout (256 bits total):
///      - bits 255-224: numOrders (uint32)
///      - bits 223-112: saleRateDeltaToken0 (int112)
///      - bits 111-0:   saleRateDeltaToken1 (int112)
type TimeInfo is bytes32;

using {numOrders, saleRateDeltaToken0, saleRateDeltaToken1, parse} for TimeInfo global;

function numOrders(TimeInfo info) pure returns (uint32 n) {
    assembly ("memory-safe") {
        n := shr(224, info)
    }
}

function saleRateDeltaToken0(TimeInfo info) pure returns (int112 delta) {
    assembly ("memory-safe") {
        delta := signextend(13, shr(112, info))
    }
}

function saleRateDeltaToken1(TimeInfo info) pure returns (int112 delta) {
    assembly ("memory-safe") {
        delta := signextend(13, info)
    }
}

function parse(TimeInfo info) pure returns (uint32 n, int112 delta0, int112 delta1) {
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
        info := or(
            shl(224, _numOrders),
            or(
                shl(112, and(_saleRateDeltaToken0, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                and(_saleRateDeltaToken1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            )
        )
    }
}
