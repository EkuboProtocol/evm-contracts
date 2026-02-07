// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed configuration for an auction
type AuctionConfig is bytes32;

using {
    creatorFee,
    isSellingToken1,
    boostDuration,
    graduationPoolFee,
    graduationPoolTickSpacing,
    startTime,
    auctionDuration,
    endTime
} for AuctionConfig global;

/// @notice Extracts the creator fee (0.64 fixed-point) from an auction config
function creatorFee(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := shr(192, config)
    }
}

/// @notice Extracts isSellingToken1 from an auction config
function isSellingToken1(AuctionConfig config) pure returns (bool v) {
    assembly ("memory-safe") {
        v := iszero(iszero(byte(8, config)))
    }
}

/// @notice Extracts boost duration from an auction config
function boostDuration(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(160, config), 0xffffff)
    }
}

/// @notice Extracts graduation pool fee (0.64 fixed-point) from an auction config
function graduationPoolFee(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(96, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts graduation pool tick spacing from an auction config
function graduationPoolTickSpacing(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(72, config), 0xffffff)
    }
}

/// @notice Extracts the auction start time from an auction config
function startTime(AuctionConfig config) pure returns (uint40 v) {
    assembly ("memory-safe") {
        v := and(shr(32, config), 0xffffffffff)
    }
}

/// @notice Extracts the auction duration from an auction config
function auctionDuration(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(8, config), 0xffffff)
    }
}

/// @notice Computes the auction end time
function endTime(AuctionConfig config) pure returns (uint64 v) {
    v = uint64(config.startTime()) + uint64(config.auctionDuration());
}

/// @notice Creates an AuctionConfig from individual components
function createAuctionConfig(
    uint64 _creatorFee,
    bool _isSellingToken1,
    uint24 _boostDuration,
    uint64 _graduationPoolFee,
    uint24 _graduationPoolTickSpacing,
    uint40 _startTime,
    uint24 _auctionDuration
) pure returns (AuctionConfig v) {
    assembly ("memory-safe") {
        v := add(
            add(
                shl(192, and(_creatorFee, 0xffffffffffffffff)),
                add(shl(184, iszero(iszero(_isSellingToken1))), shl(160, and(_boostDuration, 0xffffff)))
            ),
            add(
                add(
                    shl(96, and(_graduationPoolFee, 0xffffffffffffffff)),
                    shl(72, and(_graduationPoolTickSpacing, 0xffffff))
                ),
                add(shl(32, and(_startTime, 0xffffffffff)), shl(8, and(_auctionDuration, 0xffffff)))
            )
        )
    }
}
