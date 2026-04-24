// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Locker} from "./locker.sol";

/// @notice Signed swap metadata packed into a single word.
/// @dev Layout:
/// - bits [255..224]: deadline (uint32)
/// - bits [223..192]: fee (uint32)
/// - bits [191..128]: nonce (uint64)
/// - bits [127..0]: authorized locker lower 128 bits
type SignedSwapMeta is uint256;

using {authorizedLockerLow128, isAuthorized, deadline, fee, nonce, isExpired} for SignedSwapMeta global;

function authorizedLockerLow128(SignedSwapMeta meta) pure returns (uint128 lockerLow128) {
    assembly ("memory-safe") {
        lockerLow128 := and(meta, 0xffffffffffffffffffffffffffffffff)
    }
}

function isAuthorized(SignedSwapMeta meta, Locker locker) pure returns (bool authorized) {
    assembly ("memory-safe") {
        let shiftedMeta := shl(128, meta)
        authorized := or(iszero(shiftedMeta), eq(shl(128, locker), shiftedMeta))
    }
}

function deadline(SignedSwapMeta meta) pure returns (uint32 value) {
    assembly ("memory-safe") {
        value := shr(224, meta)
    }
}

function fee(SignedSwapMeta meta) pure returns (uint32 value) {
    assembly ("memory-safe") {
        value := and(shr(192, meta), 0xffffffff)
    }
}

function nonce(SignedSwapMeta meta) pure returns (uint64 value) {
    assembly ("memory-safe") {
        value := and(shr(128, meta), 0xffffffffffffffff)
    }
}

function createSignedSwapMeta(address _authorizedLocker, uint32 _deadline, uint32 _fee, uint64 _nonce)
    pure
    returns (SignedSwapMeta meta)
{
    assembly ("memory-safe") {
        meta := or(
            or(shl(224, _deadline), shl(192, _fee)),
            or(shl(128, _nonce), and(_authorizedLocker, 0xffffffffffffffffffffffffffffffff))
        )
    }
}

/// @notice Returns true if the deadline is expired relative to `currentTimestamp`.
/// @dev Uses modulo-2^32 comparison to remain valid across uint32 timestamp rollover.
function isExpired(SignedSwapMeta meta, uint32 currentTimestamp) pure returns (bool expired) {
    unchecked {
        expired = int32(deadline(meta) - currentTimestamp) < 0;
    }
}
