// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

/// @notice A drop is specified by an owner, token and a root
/// @dev The owner can reclaim the drop token at any time
///      The root is the root of a merkle trie that contains all the incentives to be distributed
struct DropKey {
    /// @notice Address that owns the drop and can reclaim tokens
    address owner;
    /// @notice Token address for the drop
    address token;
    /// @notice Merkle root of the incentive distribution tree
    bytes32 root;
}

using {toDropId} for DropKey global;

/// @notice Returns the identifier of the drop
/// @param key The drop key to hash
/// @return h The unique drop identifier
function toDropId(DropKey memory key) pure returns (bytes32 h) {
    assembly ("memory-safe") {
        // assumes that owner, token have no dirty upper bits
        h := keccak256(key, 96)
    }
}
