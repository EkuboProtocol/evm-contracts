// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {IIncentives, ClaimKey} from "../interfaces/IIncentives.sol";
import {IncentivesLib} from "../libraries/IncentivesLib.sol";
import {DropKey} from "../types/dropKey.sol";
import {Bitmap} from "../types/bitmap.sol";

/// @title Incentives Data Fetcher
/// @author Ekubo Protocol
/// @notice Provides functions to fetch data from the Incentives contract
/// @dev Uses IncentivesLib for efficient storage access
contract IncentivesDataFetcher {
    using IncentivesLib for IIncentives;

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch();
    /// @notice The Incentives contract instance

    IIncentives public immutable INCENTIVES;

    /// @notice Constructs the IncentivesDataFetcher with an Incentives instance
    /// @param _incentives The Incentives contract to fetch data from
    constructor(IIncentives _incentives) {
        INCENTIVES = _incentives;
    }

    /// @notice Checks if a specific index has been claimed for a drop
    /// @param key The drop key to check
    /// @param index The index to check
    /// @return True if the index has been claimed
    function isClaimed(DropKey memory key, uint256 index) external view returns (bool) {
        return INCENTIVES.isClaimed(key, index);
    }

    /// @notice Checks if a claim is available (not claimed and sufficient funds)
    /// @param key The drop key to check
    /// @param index The index to check
    /// @param amount The amount to check availability for
    /// @return True if the claim is available
    function isAvailable(DropKey memory key, uint256 index, uint128 amount) external view returns (bool) {
        return INCENTIVES.isAvailable(key, index, amount);
    }

    /// @notice Gets the remaining amount available for claims in a drop
    /// @param key The drop key to check
    /// @return The remaining amount available
    function getRemaining(DropKey memory key) external view returns (uint128) {
        return INCENTIVES.getRemaining(key);
    }

    /// @notice Represents the complete state of a drop
    struct DropInfo {
        /// @notice The drop key
        DropKey key;
        /// @notice Total amount funded for the drop
        uint128 funded;
        /// @notice Total amount claimed from the drop
        uint128 claimed;
        /// @notice Remaining amount available for claims
        uint128 remaining;
    }

    /// @notice Represents claim status information
    struct ClaimInfo {
        /// @notice The claim details
        ClaimKey claim;
        /// @notice Whether the claim has been made
        bool isClaimed;
        /// @notice Whether the claim is available (not claimed and sufficient funds)
        bool isAvailable;
    }

    /// @notice Gets complete information about a drop
    /// @param key The drop key to get information for
    /// @return info Complete drop information
    function getDropInfo(DropKey memory key) external view returns (DropInfo memory info) {
        info.key = key;
        info.funded = INCENTIVES.getFunded(key);
        info.claimed = INCENTIVES.getClaimed(key);
        info.remaining = INCENTIVES.getRemaining(key);
    }

    /// @notice Gets information about multiple drops
    /// @param keys Array of drop keys to get information for
    /// @return infos Array of drop information
    function getDropInfos(DropKey[] memory keys) external view returns (DropInfo[] memory infos) {
        infos = new DropInfo[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            infos[i].key = keys[i];
            infos[i].funded = INCENTIVES.getFunded(keys[i]);
            infos[i].claimed = INCENTIVES.getClaimed(keys[i]);
            infos[i].remaining = INCENTIVES.getRemaining(keys[i]);
        }
    }

    /// @notice Gets claim status information for a specific claim
    /// @param key The drop key
    /// @param claim The claim to check
    /// @return info ClaimKey status information
    function getClaimInfo(DropKey memory key, ClaimKey memory claim) external view returns (ClaimInfo memory info) {
        info.claim = claim;
        info.isClaimed = INCENTIVES.isClaimed(key, claim.index);
        info.isAvailable = INCENTIVES.isAvailable(key, claim.index, claim.amount);
    }

    /// @notice Gets claim status information for multiple claims
    /// @param key The drop key
    /// @param claims Array of claims to check
    /// @return infos Array of claim status information
    function getClaimInfos(DropKey memory key, ClaimKey[] memory claims)
        external
        view
        returns (ClaimInfo[] memory infos)
    {
        infos = new ClaimInfo[](claims.length);
        for (uint256 i = 0; i < claims.length; i++) {
            infos[i].claim = claims[i];
            infos[i].isClaimed = INCENTIVES.isClaimed(key, claims[i].index);
            infos[i].isAvailable = INCENTIVES.isAvailable(key, claims[i].index, claims[i].amount);
        }
    }

    /// @notice Checks if multiple indices have been claimed for a drop
    /// @param key The drop key to check
    /// @param indices Array of indices to check
    /// @return claimed Array of booleans indicating if each index has been claimed
    function areIndicesClaimed(DropKey memory key, uint256[] memory indices)
        external
        view
        returns (bool[] memory claimed)
    {
        claimed = new bool[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            claimed[i] = INCENTIVES.isClaimed(key, indices[i]);
        }
    }

    /// @notice Gets the claimed bitmap for a specific word in a drop
    /// @param key The drop key
    /// @param word The word index in the bitmap
    /// @return bitmap The claimed bitmap for the specified word
    function getClaimedBitmap(DropKey memory key, uint256 word) external view returns (Bitmap bitmap) {
        return INCENTIVES.getClaimedBitmap(key, word);
    }

    /// @notice Gets multiple claimed bitmaps for a drop
    /// @param key The drop key
    /// @param words Array of word indices to get bitmaps for
    /// @return bitmaps Array of claimed bitmaps
    function getClaimedBitmaps(DropKey memory key, uint256[] memory words)
        external
        view
        returns (Bitmap[] memory bitmaps)
    {
        bitmaps = new Bitmap[](words.length);
        for (uint256 i = 0; i < words.length; i++) {
            bitmaps[i] = INCENTIVES.getClaimedBitmap(key, words[i]);
        }
    }

    /// @notice Gets the remaining amounts for multiple drops
    /// @param keys Array of drop keys to check
    /// @return remaining Array of remaining amounts
    function getRemainingAmounts(DropKey[] memory keys) external view returns (uint128[] memory remaining) {
        remaining = new uint128[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            remaining[i] = INCENTIVES.getRemaining(keys[i]);
        }
    }

    /// @notice Checks if multiple claims are available for a drop
    /// @param key The drop key to check
    /// @param indices Array of indices to check
    /// @param amounts Array of amounts to check availability for
    /// @return available Array of booleans indicating if each claim is available
    function areClaimsAvailable(DropKey memory key, uint256[] memory indices, uint128[] memory amounts)
        external
        view
        returns (bool[] memory available)
    {
        if (indices.length != amounts.length) revert ArrayLengthMismatch();

        available = new bool[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            available[i] = INCENTIVES.isAvailable(key, indices[i], amounts[i]);
        }
    }
}
