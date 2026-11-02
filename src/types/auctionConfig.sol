// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed configuration for an auction
type AuctionConfig is bytes32;

using {
    creatorFee,
    isSellingToken1,
    minBoostDuration,
    graduationPoolFee,
    graduationPoolTickSpacing,
    startTime,
    auctionDuration,
    endTime
} for AuctionConfig global;

/// @notice Extracts the creator fee (0.16 fixed-point) from an auction config
function creatorFee(AuctionConfig config) pure returns (uint16 v) {
    assembly ("memory-safe") {
        v := and(shr(240, config), 0xffff)
    }
}

/// @notice Extracts isSellingToken1 from an auction config
function isSellingToken1(AuctionConfig config) pure returns (bool v) {
    assembly ("memory-safe") {
        v := iszero(iszero(byte(4, config)))
    }
}

/// @notice Extracts minimum boost duration from an auction config
function minBoostDuration(AuctionConfig config) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(192, config), 0xffffff)
    }
}

/// @notice Extracts graduation pool fee (0.16 fixed-point) from an auction config
function graduationPoolFee(AuctionConfig config) pure returns (uint16 v) {
    assembly ("memory-safe") {
        v := and(shr(128, config), 0xffff)
    }
}

/// @notice Extracts graduation pool tick spacing exponent from an auction config
/// @dev The spacing itself is `1 << exp`
function graduationPoolTickSpacing(AuctionConfig config) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(shr(96, config), 0xff)
    }
}

/// @notice Extracts the auction start time from an auction config
function startTime(AuctionConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(32, config), 0xffffffffffffffff)
    }
}

/// @notice Extracts the auction duration from an auction config
function auctionDuration(AuctionConfig config) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(config, 0xffffffff)
    }
}

/// @notice Computes the auction end time
function endTime(AuctionConfig config) pure returns (uint64 v) {
    unchecked {
        v = uint64(config.startTime()) + uint64(config.auctionDuration());
    }
}

/// @notice Creates an AuctionConfig from individual components
/// @dev Bits left unused by the narrowed fee/spacing fields are reserved and must be zero.
function createAuctionConfig(
    uint16 _creatorFee,
    bool _isSellingToken1,
    uint24 _minBoostDuration,
    uint16 _graduationPoolFee,
    uint8 _graduationPoolTickSpacingExp,
    uint64 _startTime,
    uint32 _auctionDuration
) pure returns (AuctionConfig v) {
    assembly ("memory-safe") {
        v := add(
            add(
                shl(240, and(_creatorFee, 0xffff)),
                add(shl(216, iszero(iszero(_isSellingToken1))), shl(192, and(_minBoostDuration, 0xffffff)))
            ),
            add(
                add(shl(128, and(_graduationPoolFee, 0xffff)), shl(96, and(_graduationPoolTickSpacingExp, 0xff))),
                add(shl(32, and(_startTime, 0xffffffffffffffff)), and(_auctionDuration, 0xffffffff))
            )
        )
    }
}
