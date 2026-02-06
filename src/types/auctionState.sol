// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @notice Packed state for an auction
type AuctionState is bytes32;

using {creatorCollectionPercentage, boostDuration, graduationPoolFee, graduationPoolTickSpacing, totalAmountSold, parse}
    for AuctionState global;

function creatorCollectionPercentage(AuctionState state) pure returns (uint8 v) {
    assembly ("memory-safe") {
        v := and(state, 0xff)
    }
}

function boostDuration(AuctionState state) pure returns (uint24 v) {
    assembly ("memory-safe") {
        v := and(shr(8, state), 0xffffff)
    }
}

function graduationPoolFee(AuctionState state) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(32, state), 0xffffffffffffffff)
    }
}

function graduationPoolTickSpacing(AuctionState state) pure returns (uint32 v) {
    assembly ("memory-safe") {
        v := and(shr(96, state), 0xffffffff)
    }
}

function totalAmountSold(AuctionState state) pure returns (uint128 v) {
    assembly ("memory-safe") {
        v := shr(128, state)
    }
}

function parse(AuctionState state)
    pure
    returns (
        uint8 _creatorCollectionPercentage,
        uint24 _boostDuration,
        uint64 _graduationPoolFee,
        uint32 _graduationPoolTickSpacing,
        uint128 _totalAmountSold
    )
{
    _creatorCollectionPercentage = state.creatorCollectionPercentage();
    _boostDuration = state.boostDuration();
    _graduationPoolFee = state.graduationPoolFee();
    _graduationPoolTickSpacing = state.graduationPoolTickSpacing();
    _totalAmountSold = state.totalAmountSold();
}

function createAuctionState(
    uint8 _creatorCollectionPercentage,
    uint24 _boostDuration,
    uint64 _graduationPoolFee,
    uint32 _graduationPoolTickSpacing,
    uint128 _totalAmountSold
) pure returns (AuctionState state) {
    assembly ("memory-safe") {
        state := or(
            or(
                or(
                    shl(128, and(_totalAmountSold, 0xffffffffffffffffffffffffffffffff)),
                    shl(96, and(_graduationPoolTickSpacing, 0xffffffff))
                ),
                shl(32, and(_graduationPoolFee, 0xffffffffffffffff))
            ),
            or(shl(8, and(_boostDuration, 0xffffff)), and(_creatorCollectionPercentage, 0xff))
        )
    }
}
