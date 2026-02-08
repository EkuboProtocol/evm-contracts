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
        v := shl(32, shr(224, config))
    }
}

/// @notice Extracts isSellingToken1 from an auction config
function isSellingToken1(AuctionConfig config) pure returns (bool v) {
    assembly ("memory-safe") {
        v := iszero(iszero(byte(4, config)))
    }
}

/// @notice Extracts boost duration from an auction config
function boostDuration(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(192, config), 0xffffff)
    }
}

/// @notice Extracts graduation pool fee (0.64 fixed-point) from an auction config
function graduationPoolFee(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(128, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts graduation pool tick spacing from an auction config
function graduationPoolTickSpacing(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(104, config), 0xffffff)
    }
}

/// @notice Extracts the auction start time from an auction config
function startTime(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(40, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the auction duration from an auction config
function auctionDuration(AuctionConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(8, config), 0xffffffff)
    }
}

/// @notice Computes the auction end time
function endTime(AuctionConfig config) pure returns (uint64 v) {
    unchecked {
        v = uint64(config.startTime()) + uint64(config.auctionDuration());
    }
}

/// @notice Creates an AuctionConfig from individual components
function createAuctionConfig(
    uint32 _creatorFee,
    bool _isSellingToken1,
    uint24 _boostDuration,
    uint64 _graduationPoolFee,
    uint24 _graduationPoolTickSpacing,
    uint64 _startTime,
    uint32 _auctionDuration
) pure returns (AuctionConfig v) {
    assembly ("memory-safe") {
        v := add(
            add(
                shl(224, and(_creatorFee, 0xffffffff)),
                add(shl(216, iszero(iszero(_isSellingToken1))), shl(192, and(_boostDuration, 0xffffff)))
            ),
            add(
                add(
                    shl(128, and(_graduationPoolFee, 0xffffffffffffffff)),
                    shl(104, and(_graduationPoolTickSpacing, 0xffffff))
                ),
                add(shl(40, and(_startTime, 0xffffffffffffffff)), shl(8, and(_auctionDuration, 0xffffffff)))
            )
        )
    }
}
