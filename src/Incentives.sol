// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "./math/bitmap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

// A drop is specified by an owner, token and a root
// The owner can reclaim the drop token at any time
// The root is the root of a merkle trie that contains all the incentives to be distributed
struct DropKey {
    address owner;
    address token;
    bytes32 root;
}

// Returns the identifier of the drop
function toDropId(DropKey memory key) pure returns (bytes32) {
    return EfficientHashLib.hash(bytes32(bytes20(key.owner)), bytes32(bytes20(key.token)), key.root);
}

// A claim is an individual leaf in the merkle trie
struct Claim {
    uint256 index;
    address account;
    uint128 amount;
}

function hashClaim(Claim memory c) pure returns (bytes32 h) {
    assembly ("memory-safe") {
        // assumes that account has no dirty upper bits
        h := keccak256(c, 96)
    }
}

function indexToWordBit(uint256 index) pure returns (uint256 word, uint8 bit) {
    (word, bit) = (index >> 8, uint8(index % 256));
}

/// @author Moody Salem
/// @notice A singleton contract for making many airdrops
contract Incentives is Multicallable {
    using {toDropId} for DropKey;
    using {hashClaim} for Claim;

    /// @notice Emitted when a drop is funded
    event Funded(DropKey key, uint128 amountNext);
    /// @notice Emitted when a drop is funded
    event Refunded(DropKey key, uint128 refundAmount);

    /// @notice Thrown if the claim has already happened for this drop
    error AlreadyClaimed();
    /// @notice Thrown if the merkle proof does not correspond to the root
    error InvalidProof();
    /// @notice Thrown if the drop is not sufficiently funded for the claim
    error InsufficientFunds();
    /// @notice Only the drop owner may call this function
    error DropOwnerOnly();

    struct DropState {
        uint128 funded;
        uint128 claimed;
    }

    mapping(bytes32 id => DropState) private state;
    mapping(bytes32 id => mapping(uint256 => Bitmap)) public claimed;

    function _isClaimed(bytes32 dropId, uint256 index) private view returns (bool) {
        (uint256 word, uint8 bit) = indexToWordBit(index);
        return claimed[dropId][word].isSet(bit);
    }

    function isAvailable(DropKey memory key, uint256 index, uint128 amount) external view returns (bool) {
        bytes32 id = key.toDropId();

        DropState memory drop = state[id];
        unchecked {
            return !_isClaimed(id, index) && (drop.funded - drop.claimed) >= amount;
        }
    }

    function getRemaining(DropKey memory key) external view returns (uint128) {
        bytes32 id = key.toDropId();

        DropState memory drop = state[id];
        unchecked {
            return (drop.funded - drop.claimed);
        }
    }

    function fund(DropKey memory key, uint128 minimum) external returns (uint128 fundedAmount) {
        bytes32 id = key.toDropId();
        DropState memory drop = state[id];

        if (drop.funded < minimum) {
            fundedAmount = minimum - drop.funded;
            drop.funded = minimum;
            state[id] = drop;
            SafeTransferLib.safeTransferFrom(key.token, msg.sender, address(this), fundedAmount);
            emit Funded(key, minimum);
        }
    }

    function refund(DropKey memory key) external returns (uint128 refundAmount) {
        unchecked {
            if (msg.sender != key.owner) {
                revert DropOwnerOnly();
            }
            DropState storage s = state[key.toDropId()];
            refundAmount = s.funded - s.claimed;
            if (refundAmount > 0) {
                s.funded = s.claimed;
                SafeTransferLib.safeTransfer(key.token, key.owner, refundAmount);
                emit Refunded(key, refundAmount);
            }
        }
    }

    function claim(DropKey memory key, Claim memory c, bytes32[] calldata proof) external virtual {
        bytes32 id = key.toDropId();

        // Check that it is not claimed
        (uint256 word, uint8 bit) = indexToWordBit(c.index);
        Bitmap b = claimed[id][word];
        if (b.isSet(bit)) revert AlreadyClaimed();

        // Check the proof is valid
        bytes32 leaf = hashClaim(c);
        if (!MerkleProofLib.verify(proof, key.root, leaf)) revert InvalidProof();

        // Get the state
        DropState storage drop = state[id];

        uint256 remaining = drop.funded - drop.claimed;

        if (remaining < c.amount) {
            revert InsufficientFunds();
        }

        // Checked addition prevents overflow here
        drop.claimed += c.amount;

        claimed[id][word] = b.toggle(bit);

        SafeTransferLib.safeTransfer(key.token, c.account, c.amount);
    }
}
