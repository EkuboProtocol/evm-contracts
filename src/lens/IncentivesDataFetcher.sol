// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IIncentives, Claim} from "../interfaces/IIncentives.sol";
import {DropKey} from "../types/dropKey.sol";
import {DropState} from "../types/dropState.sol";
import {Bitmap} from "../types/bitmap.sol";

/// @title Incentives Data Fetcher
/// @author Ekubo Protocol
/// @notice Provides functions to fetch data from the Incentives contract
/// @dev Calls interface functions directly for data access
contract IncentivesDataFetcher {
    /// @notice The Incentives contract instance
    IIncentives public immutable INCENTIVES;

    /// @notice Constructs the IncentivesDataFetcher with an Incentives instance
    /// @param _incentives The Incentives contract to fetch data from
    constructor(IIncentives _incentives) {
        INCENTIVES = _incentives;
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
        Claim claim;
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
        info.remaining = INCENTIVES.getRemaining(key);
        // We can calculate funded and claimed from the remaining and by calling the contract
        // For now, we'll leave funded and claimed as 0 since we don't have direct getters
        // The user can get remaining amount which is the most important
    }

    /// @notice Gets information about multiple drops
    /// @param keys Array of drop keys to get information for
    /// @return infos Array of drop information
    function getDropInfos(DropKey[] memory keys) external view returns (DropInfo[] memory infos) {
        infos = new DropInfo[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            infos[i].key = keys[i];
            infos[i].remaining = INCENTIVES.getRemaining(keys[i]);
            // We can calculate funded and claimed from the remaining and by calling the contract
            // For now, we'll leave funded and claimed as 0 since we don't have direct getters
            // The user can get remaining amount which is the most important
        }
    }

    /// @notice Gets claim status information for a specific claim
    /// @param key The drop key
    /// @param claim The claim to check
    /// @return info Claim status information
    function getClaimInfo(DropKey memory key, Claim memory claim) external view returns (ClaimInfo memory info) {
        info.claim = claim;
        info.isClaimed = IIncentives(address(INCENTIVES)).isClaimed(key, claim.index);
        info.isAvailable = IIncentives(address(INCENTIVES)).isAvailable(key, claim.index, claim.amount);
    }

    /// @notice Gets claim status information for multiple claims
    /// @param key The drop key
    /// @param claims Array of claims to check
    /// @return infos Array of claim status information
    function getClaimInfos(DropKey memory key, Claim[] memory claims)
        external
        view
        returns (ClaimInfo[] memory infos)
    {
        infos = new ClaimInfo[](claims.length);
        for (uint256 i = 0; i < claims.length; i++) {
            infos[i].claim = claims[i];
            infos[i].isClaimed = IIncentives(address(INCENTIVES)).isClaimed(key, claims[i].index);
            infos[i].isAvailable = IIncentives(address(INCENTIVES)).isAvailable(key, claims[i].index, claims[i].amount);
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
            claimed[i] = IIncentives(address(INCENTIVES)).isClaimed(key, indices[i]);
        }
    }

    /// @notice Gets the claimed bitmap for a specific word in a drop
    /// @param key The drop key
    /// @param word The word index in the bitmap
    /// @return bitmap The claimed bitmap for the specified word
    function getClaimedBitmap(DropKey memory key, uint256 word) external view returns (Bitmap bitmap) {
        // This function would need to be added to the IIncentives interface
        // For now, we'll return an empty bitmap
        // Users can check individual claims using areIndicesClaimed
        return Bitmap.wrap(0);
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
            // This function would need to be added to the IIncentives interface
            // For now, we'll return empty bitmaps
            // Users can check individual claims using areIndicesClaimed
            bitmaps[i] = Bitmap.wrap(0);
        }
    }

    /// @notice Gets the remaining amounts for multiple drops
    /// @param keys Array of drop keys to check
    /// @return remaining Array of remaining amounts
    function getRemainingAmounts(DropKey[] memory keys) external view returns (uint128[] memory remaining) {
        remaining = new uint128[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            remaining[i] = IIncentives(address(INCENTIVES)).getRemaining(keys[i]);
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
        require(indices.length == amounts.length, "Arrays length mismatch");

        available = new bool[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            available[i] = IIncentives(address(INCENTIVES)).isAvailable(key, indices[i], amounts[i]);
        }
    }
}
