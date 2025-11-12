// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

/// @notice A claim is an individual leaf in the merkle trie
struct ClaimKey {
    /// @notice Index of the claim in the merkle tree
    uint256 index;
    /// @notice Account that can claim the incentive
    address account;
    /// @notice Amount of tokens to be claimed
    uint128 amount;
}

using {toClaimId} for ClaimKey global;

/// @notice Hashes a claim for merkle proof verification
/// @param c The claim to hash
/// @return h The hash of the claim
function toClaimId(ClaimKey memory c) pure returns (bytes32 h) {
    assembly ("memory-safe") {
        // assumes that account has no dirty upper bits
        h := keccak256(c, 96)
    }
}
