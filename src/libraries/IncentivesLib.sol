// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {IIncentives} from "../interfaces/IIncentives.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {DropKey, toDropId} from "../types/dropKey.sol";
import {DropState} from "../types/dropState.sol";
import {Bitmap} from "../types/bitmap.sol";

/// @title Incentives Library
/// @notice Library providing common storage getters for the Incentives contract
/// @dev These functions access Incentives contract storage directly for gas efficiency
library IncentivesLib {
    using ExposedStorageLib for *;
    using {toDropId} for DropKey;

    /// @notice Converts an index to word and bit position for bitmap storage
    /// @param index The index to convert
    /// @return word The word position in the bitmap
    /// @return bit The bit position within the word
    function claimIndexToStorageIndex(uint256 index) internal pure returns (uint256 word, uint8 bit) {
        (word, bit) = (index >> 8, uint8(index % 256));
    }

    /// @notice Gets the drop state for a given drop key
    /// @dev Accesses the incentives contract's storage directly for gas efficiency
    /// @param incentives The incentives contract instance
    /// @param key The drop key to get state for
    /// @return state The drop state containing funded and claimed amounts
    function getDropState(IIncentives incentives, DropKey memory key) internal view returns (DropState state) {
        bytes32 dropId = key.toDropId();
        state = DropState.wrap(incentives.sload(dropId));
    }

    /// @notice Gets the claimed bitmap for a specific drop and word
    /// @dev Accesses the incentives contract's storage directly for gas efficiency
    /// @param incentives The incentives contract instance
    /// @param key The drop key
    /// @param word The word index in the bitmap
    /// @return bitmap The claimed bitmap for the specified word
    function getClaimedBitmap(IIncentives incentives, DropKey memory key, uint256 word)
        internal
        view
        returns (Bitmap bitmap)
    {
        bytes32 dropId = key.toDropId();
        // Bitmaps are stored starting from drop id + 1 + word
        bytes32 slot;
        unchecked {
            slot = bytes32(uint256(dropId) + 1 + word);
        }
        bitmap = Bitmap.wrap(uint256(incentives.sload(slot)));
    }

    /// @notice Checks if a specific index has been claimed for a drop
    /// @param incentives The incentives contract instance
    /// @param key The drop key to check
    /// @param index The index to check
    /// @return True if the index has been claimed
    function isClaimed(IIncentives incentives, DropKey memory key, uint256 index) internal view returns (bool) {
        (uint256 word, uint8 bit) = claimIndexToStorageIndex(index);
        Bitmap bitmap = getClaimedBitmap(incentives, key, word);
        // Convert from old (LSB=0) to new (MSB=0) bit index
        return bitmap.isSet(uint8(255 - bit));
    }

    /// @notice Checks if a claim is available (not claimed and sufficient funds)
    /// @param incentives The incentives contract instance
    /// @param key The drop key to check
    /// @param index The index to check
    /// @param amount The amount to check availability for
    /// @return True if the claim is available
    function isAvailable(IIncentives incentives, DropKey memory key, uint256 index, uint128 amount)
        internal
        view
        returns (bool)
    {
        if (isClaimed(incentives, key, index)) return false;

        DropState state = getDropState(incentives, key);
        return state.getRemaining() >= amount;
    }

    /// @notice Gets the remaining amount available for claims in a drop
    /// @param incentives The incentives contract instance
    /// @param key The drop key to check
    /// @return The remaining amount available
    function getRemaining(IIncentives incentives, DropKey memory key) internal view returns (uint128) {
        DropState state = getDropState(incentives, key);
        return state.getRemaining();
    }

    /// @notice Gets the funded amount for a drop
    /// @param incentives The incentives contract instance
    /// @param key The drop key to check
    /// @return The funded amount
    function getFunded(IIncentives incentives, DropKey memory key) internal view returns (uint128) {
        DropState state = getDropState(incentives, key);
        return state.funded();
    }

    /// @notice Gets the claimed amount for a drop
    /// @param incentives The incentives contract instance
    /// @param key The drop key to check
    /// @return The claimed amount
    function getClaimed(IIncentives incentives, DropKey memory key) internal view returns (uint128) {
        DropState state = getDropState(incentives, key);
        return state.claimed();
    }
}
