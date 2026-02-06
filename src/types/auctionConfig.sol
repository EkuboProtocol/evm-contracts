// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed configuration for launching an auction (token, start time, duration)
type AuctionConfig is bytes32;

using {token, startTime, duration} for AuctionConfig global;

/// @notice Extracts the token from an auction config
function token(AuctionConfig config) pure returns (address v) {
    assembly ("memory-safe") {
        v := shr(96, config)
    }
}

/// @notice Extracts the start time from an auction config
function startTime(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(32, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the duration from an auction config
function duration(AuctionConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(config, 0xffffffff)
    }
}

/// @notice Creates an AuctionConfig from individual components
function createAuctionConfig(address _token, uint64 _startTime, uint32 _duration) pure returns (AuctionConfig v) {
    assembly ("memory-safe") {
        v := or(
            or(
                shl(96, and(_token, 0xffffffffffffffffffffffffffffffffffffffff)),
                shl(32, and(_startTime, 0xffffffffffffffff))
            ),
            and(_duration, 0xffffffff)
        )
    }
}
