// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {StorageSlot} from "../types/storageSlot.sol";

/// @title Exchequer Auctions Storage Layout
/// @notice Library providing functions to compute storage locations for the ExchequerAuctions contract.
/// @dev ExchequerAuctions has no declared mutable storage; all state is accessed through these slots
///      and read from outside through `IExposedStorage.sload`. Slots 5 through 9 mirror the
///      contract's constructor immutables and are written once.
library ExchequerAuctionsStorageLayout {
    /// @dev licenseLastClose u128 | licenseLastCloseDay u64, low to high
    uint256 internal constant LICENSE_LAST_SLOT = 0;
    /// @dev licenseDayOpen u128 | licenseOpenDay u64, low to high
    uint256 internal constant LICENSE_OPEN_SLOT = 1;
    /// @dev charterLastClose u128 | charterLastCloseDay u64, low to high
    uint256 internal constant CHARTER_LAST_SLOT = 2;
    /// @dev charterDayOpen u128 | charterOpenDay u64, low to high
    uint256 internal constant CHARTER_OPEN_SLOT = 3;
    /// @dev charterReservePrice u128 | chartersPerDay u64, low to high
    uint256 internal constant CHARTER_POLICY_SLOT = 4;

    // Mirrors of immutables
    uint256 internal constant BANK_SLOT = 5;
    uint256 internal constant LICENSES_PER_DAY_SLOT = 6;
    uint256 internal constant LICENSE_FLOOR_YIELD_DAYS_SLOT = 7;
    uint256 internal constant LICENSE_FLOOR_MINIMUM_SLOT = 8;
    uint256 internal constant MAX_CHARTERS_PER_DAY_SLOT = 9;
    uint256 internal constant ISSUE_TOKEN_SLOT = 10;

    /// @dev Generated using: cast keccak "ExchequerAuctionsStorageLayout#SOLD_ON_DAY"
    bytes32 internal constant SOLD_ON_DAY_OFFSET = 0xb391c605f23de3251e72c3619ffec9e2ebac51df153b06d9a438fbfdfcdbe146;

    function slot(uint256 index) internal pure returns (StorageSlot) {
        return StorageSlot.wrap(bytes32(index));
    }

    /// @notice Sales on a day: licenses (low 128) | charters (high 128)
    function soldOnDaySlot(uint256 day) internal pure returns (StorageSlot) {
        return StorageSlot.wrap(EfficientHashLib.hash(bytes32(day), SOLD_ON_DAY_OFFSET));
    }

    function packPriceAndDay(uint128 price, uint64 day) internal pure returns (bytes32) {
        return bytes32(uint256(price) | (uint256(day) << 128));
    }

    function unpackPriceAndDay(bytes32 word) internal pure returns (uint128 price, uint64 day) {
        uint256 v = uint256(word);
        price = uint128(v);
        day = uint64(v >> 128);
    }

    function packTwo128(uint128 low, uint128 high) internal pure returns (bytes32) {
        return bytes32((uint256(high) << 128) | uint256(low));
    }

    function unpackTwo128(bytes32 word) internal pure returns (uint128 low, uint128 high) {
        low = uint128(uint256(word));
        high = uint128(uint256(word) >> 128);
    }
}
