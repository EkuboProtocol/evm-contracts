// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {DropKey} from "../types/dropKey.sol";
import {IExposedStorage} from "./IExposedStorage.sol";

/// @notice A claim is an individual leaf in the merkle trie
struct Claim {
    /// @notice Index of the claim in the merkle tree
    uint256 index;
    /// @notice Account that can claim the incentive
    address account;
    /// @notice Amount of tokens to be claimed
    uint128 amount;
}

using {hashClaim} for Claim global;

/// @notice Hashes a claim for merkle proof verification
/// @param c The claim to hash
/// @return h The hash of the claim
function hashClaim(Claim memory c) pure returns (bytes32 h) {
    assembly ("memory-safe") {
        // assumes that account has no dirty upper bits
        h := keccak256(c, 96)
    }
}

/// @title Incentives Interface
/// @notice Interface for the Incentives contract that manages airdrops
/// @dev Inherits from IExposedStorage to allow direct storage access
interface IIncentives is IExposedStorage {
    /// @notice Emitted when a drop is funded
    /// @param key The drop key that was funded
    /// @param amountNext The new total funded amount
    event Funded(DropKey key, uint128 amountNext);

    /// @notice Emitted when a drop is refunded
    /// @param key The drop key that was refunded
    /// @param refundAmount The amount that was refunded
    event Refunded(DropKey key, uint128 refundAmount);

    /// @notice Thrown if the claim has already happened for this drop
    error AlreadyClaimed();

    /// @notice Thrown if the merkle proof does not correspond to the root
    error InvalidProof();

    /// @notice Thrown if the drop is not sufficiently funded for the claim
    error InsufficientFunds();

    /// @notice Only the drop owner may call this function
    error DropOwnerOnly();

    /// @notice Funds a drop to a minimum amount
    /// @param key The drop key to fund
    /// @param minimum The minimum amount to fund to
    /// @return fundedAmount The amount that was actually funded
    function fund(DropKey memory key, uint128 minimum) external returns (uint128 fundedAmount);

    /// @notice Refunds the remaining amount from a drop to the owner
    /// @param key The drop key to refund
    /// @return refundAmount The amount that was refunded
    function refund(DropKey memory key) external returns (uint128 refundAmount);

    /// @notice Claims tokens from a drop using a merkle proof
    /// @param key The drop key to claim from
    /// @param c The claim details
    /// @param proof The merkle proof for the claim
    function claim(DropKey memory key, Claim memory c, bytes32[] calldata proof) external;
}
