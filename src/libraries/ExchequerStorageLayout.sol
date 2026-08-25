// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {StorageSlot} from "../types/storageSlot.sol";

/// @title Exchequer Storage Layout
/// @notice Library providing functions to compute storage locations for the Exchequer contract.
/// @dev Exchequer has no declared mutable storage; all state is accessed through these slots and
///      read from outside through `IExposedStorage.sload`. Related words are packed into one slot
///      with the helpers below, so the contract and its readers agree on the bit layout.
///
///      Slots 4 through 11 mirror the bank's constructor immutables. They are written once, in the
///      constructor, and never again; they exist so that a reader with only `sload` can recover
///      every parameter.
library ExchequerStorageLayout {
    uint256 internal constant OWNER_SLOT = 0;
    uint256 internal constant TEAM_RECIPIENT_SLOT = 1;
    uint256 internal constant EXPANSION_VAULT_SLOT = 2;
    uint256 internal constant AUCTIONS_SLOT = 3;

    // Mirrors of immutables
    uint256 internal constant ISSUE_TOKEN_SLOT = 4;
    uint256 internal constant BANK_TOKEN_SLOT = 5;
    uint256 internal constant RESERVE_ASSET_SLOT = 6;
    /// @dev baseIssuancePerDay (low 128) | minNetFlow (high 128)
    uint256 internal constant PARAMETERS_A_SLOT = 7;
    /// @dev multiplierMin | multiplierMax | multiplierCutStep | multiplierRaiseStep, 64 bits each, low to high
    uint256 internal constant PARAMETERS_B_SLOT = 8;
    /// @dev epochLength u32 | tradingFee u64 | polReferenceWindow u32 | redistributionStreamLength u32 | tickSpacing u32, low to high
    uint256 internal constant PARAMETERS_C_SLOT = 9;
    /// @dev resolutionFeeFloor | resolutionFeeCeiling | exitPressureSaturation, 64 bits each, low to high
    uint256 internal constant PARAMETERS_D_SLOT = 10;
    /// @dev exitPressureDenominatorFloor u128
    uint256 internal constant PARAMETERS_E_SLOT = 11;

    /// @dev multiplier u64 | epochStartTime u64 | lastAccrualTime u64 | initialized u8, low to high
    uint256 internal constant POLICY_SLOT = 12;
    uint256 internal constant ISSUANCE_GROWTH_PER_SHARE_X128_SLOT = 13;
    uint256 internal constant CUMULATIVE_ISSUANCE_SLOT = 14;
    uint256 internal constant TOTAL_LEDGER_BALANCE_SLOT = 15;
    /// @dev epochEthIn (low 128) | epochEthOut (high 128)
    uint256 internal constant EPOCH_FLOW_SLOT = 16;
    /// @dev prevNetFlow (low 128, signed) | prevPrevNetFlow (high 128, signed)
    uint256 internal constant FLOW_HISTORY_SLOT = 17;
    /// @dev savedEth (low 128) | epochRevenueEth (high 128)
    uint256 internal constant FEE_ETH_SLOT = 18;
    /// @dev pendingExpansionEth (low 128) | pendingContractionEth (high 128)
    uint256 internal constant VAULT_ETH_SLOT = 19;
    /// @dev pendingPolEth (low 128) | pendingTeamEth (high 128)
    uint256 internal constant POL_ETH_SLOT = 20;
    /// @dev streamRemaining u128 | streamEndTime u64, low to high
    uint256 internal constant STREAM_SLOT = 21;
    /// @dev buybackBidLowerTick i32 | buybackBidActive u8, low to high
    uint256 internal constant BUYBACK_SLOT = 22;
    /// @dev referenceTickX24 i64 | lastObservedTick i32 | lastObservationTime u32, low to high
    uint256 internal constant REFERENCE_SLOT = 23;
    uint256 internal constant FOUNDING_BANK_MINTED_SLOT = 24;
    uint256 internal constant LAST_BUCKET_DAY_SLOT = 25;
    /// @dev Seven consecutive slots, one per day of the trailing exit window
    uint256 internal constant WITHDRAWAL_BUCKETS_SLOT = 26;

    /// @dev Generated using: cast keccak "ExchequerStorageLayout#HOLDERS"
    bytes32 internal constant HOLDERS_OFFSET = 0xc28e72aa830150894adac5f4000a19f37c22451c923681d757f3d09e84a1a5d1;

    function slot(uint256 index) internal pure returns (StorageSlot) {
        return StorageSlot.wrap(bytes32(index));
    }

    function withdrawalBucketSlot(uint256 index) internal pure returns (StorageSlot) {
        return StorageSlot.wrap(bytes32(WITHDRAWAL_BUCKETS_SLOT + index));
    }

    /// @notice The first of two consecutive slots for a holder: settled ledger, then growth snapshot
    function holderSlot(address holder) internal pure returns (StorageSlot) {
        return StorageSlot.wrap(EfficientHashLib.hash(bytes32(uint256(uint160(holder))), HOLDERS_OFFSET));
    }

    /// PACKING

    function packTwo128(uint128 low, uint128 high) internal pure returns (bytes32) {
        return bytes32((uint256(high) << 128) | uint256(low));
    }

    function unpackTwo128(bytes32 word) internal pure returns (uint128 low, uint128 high) {
        low = uint128(uint256(word));
        high = uint128(uint256(word) >> 128);
    }

    function packSigned128Pair(int128 low, int128 high) internal pure returns (bytes32) {
        return bytes32((uint256(uint128(high)) << 128) | uint256(uint128(low)));
    }

    function unpackSigned128Pair(bytes32 word) internal pure returns (int128 low, int128 high) {
        low = int128(uint128(uint256(word)));
        high = int128(uint128(uint256(word) >> 128));
    }

    function packFour64(uint64 a, uint64 b, uint64 c, uint64 d) internal pure returns (bytes32) {
        return bytes32(uint256(a) | (uint256(b) << 64) | (uint256(c) << 128) | (uint256(d) << 192));
    }

    function unpackFour64(bytes32 word) internal pure returns (uint64 a, uint64 b, uint64 c, uint64 d) {
        uint256 v = uint256(word);
        a = uint64(v);
        b = uint64(v >> 64);
        c = uint64(v >> 128);
        d = uint64(v >> 192);
    }

    function packParametersC(
        uint32 epochLength,
        uint64 tradingFee,
        uint32 polReferenceWindow,
        uint32 redistributionStreamLength,
        uint32 tickSpacing
    ) internal pure returns (bytes32) {
        return bytes32(
            uint256(epochLength) | (uint256(tradingFee) << 32) | (uint256(polReferenceWindow) << 96)
                | (uint256(redistributionStreamLength) << 128) | (uint256(tickSpacing) << 160)
        );
    }

    function unpackParametersC(bytes32 word)
        internal
        pure
        returns (
            uint32 epochLength,
            uint64 tradingFee,
            uint32 polReferenceWindow,
            uint32 redistributionStreamLength,
            uint32 tickSpacing
        )
    {
        uint256 v = uint256(word);
        epochLength = uint32(v);
        tradingFee = uint64(v >> 32);
        polReferenceWindow = uint32(v >> 96);
        redistributionStreamLength = uint32(v >> 128);
        tickSpacing = uint32(v >> 160);
    }

    function packPolicy(uint64 multiplier, uint64 epochStartTime, uint64 lastAccrualTime, bool initialized)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(multiplier) | (uint256(epochStartTime) << 64) | (uint256(lastAccrualTime) << 128)
                | (uint256(initialized ? 1 : 0) << 192)
        );
    }

    function unpackPolicy(bytes32 word)
        internal
        pure
        returns (uint64 multiplier, uint64 epochStartTime, uint64 lastAccrualTime, bool initialized)
    {
        uint256 v = uint256(word);
        multiplier = uint64(v);
        epochStartTime = uint64(v >> 64);
        lastAccrualTime = uint64(v >> 128);
        initialized = (v >> 192) & 1 == 1;
    }

    function packStream(uint128 remaining, uint64 endTime) internal pure returns (bytes32) {
        return bytes32(uint256(remaining) | (uint256(endTime) << 128));
    }

    function unpackStream(bytes32 word) internal pure returns (uint128 remaining, uint64 endTime) {
        uint256 v = uint256(word);
        remaining = uint128(v);
        endTime = uint64(v >> 128);
    }

    function packBuyback(int32 lowerTick, bool active) internal pure returns (bytes32) {
        return bytes32(uint256(uint32(lowerTick)) | (uint256(active ? 1 : 0) << 32));
    }

    function unpackBuyback(bytes32 word) internal pure returns (int32 lowerTick, bool active) {
        uint256 v = uint256(word);
        lowerTick = int32(uint32(v));
        active = (v >> 32) & 1 == 1;
    }

    function packReference(int64 referenceTickX24, int32 lastObservedTick, uint32 lastObservationTime)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(uint64(referenceTickX24)) | (uint256(uint32(lastObservedTick)) << 64)
                | (uint256(lastObservationTime) << 96)
        );
    }

    function unpackReference(bytes32 word)
        internal
        pure
        returns (int64 referenceTickX24, int32 lastObservedTick, uint32 lastObservationTime)
    {
        uint256 v = uint256(word);
        referenceTickX24 = int64(uint64(v));
        lastObservedTick = int32(uint32(v >> 64));
        lastObservationTime = uint32(v >> 96);
    }
}
