// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Signed swap metadata packed into a single word.
/// @dev Layout:
/// - bits [255..96]: authorized locker (160 bits)
/// - bits [95..64]: deadline (uint32)
/// - bits [63..32]: fee (uint32)
/// - bits [31..0]: nonce (uint32)
type SignedSwapMeta is uint256;

using {authorizedLocker, deadline, fee, nonce, isNotExpired, parseSignedSwapMeta} for SignedSwapMeta global;

function authorizedLocker(SignedSwapMeta meta) pure returns (address locker) {
    assembly ("memory-safe") {
        locker := shr(96, meta)
    }
}

function deadline(SignedSwapMeta meta) pure returns (uint32 value) {
    assembly ("memory-safe") {
        value := and(shr(64, meta), 0xffffffff)
    }
}

function fee(SignedSwapMeta meta) pure returns (uint32 value) {
    assembly ("memory-safe") {
        value := and(shr(32, meta), 0xffffffff)
    }
}

function nonce(SignedSwapMeta meta) pure returns (uint32 value) {
    assembly ("memory-safe") {
        value := and(meta, 0xffffffff)
    }
}

function parseSignedSwapMeta(SignedSwapMeta meta)
    pure
    returns (address _authorizedLocker, uint32 _deadline, uint32 _fee, uint32 _nonce)
{
    assembly ("memory-safe") {
        _authorizedLocker := shr(96, meta)
        _deadline := and(shr(64, meta), 0xffffffff)
        _fee := and(shr(32, meta), 0xffffffff)
        _nonce := and(meta, 0xffffffff)
    }
}

function createSignedSwapMeta(address _authorizedLocker, uint32 _deadline, uint32 _fee, uint32 _nonce)
    pure
    returns (SignedSwapMeta meta)
{
    assembly ("memory-safe") {
        meta := or(or(shl(96, _authorizedLocker), shl(64, _deadline)), or(shl(32, _fee), _nonce))
    }
}

/// @notice Returns true if the deadline has not expired relative to `currentTimestamp`.
/// @dev Uses modulo-2^32 comparison to remain valid across uint32 timestamp rollover.
function isNotExpired(SignedSwapMeta meta, uint32 currentTimestamp) pure returns (bool valid) {
    unchecked {
        valid = int32(deadline(meta) - currentTimestamp) >= 0;
    }
}
