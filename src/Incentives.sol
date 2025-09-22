// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Bitmap} from "./types/bitmap.sol";
import {DropKey, toDropId} from "./types/dropKey.sol";
import {DropState, toDropState} from "./types/dropState.sol";
import {IIncentives, Claim, hashClaim} from "./interfaces/IIncentives.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

/// @notice Converts an index to word and bit position for bitmap storage
/// @param index The index to convert
/// @return word The word position in the bitmap
/// @return bit The bit position within the word
function indexToWordBit(uint256 index) pure returns (uint256 word, uint8 bit) {
    (word, bit) = (index >> 8, uint8(index % 256));
}

/// @author Moody Salem
/// @notice A singleton contract for making many airdrops
contract Incentives is IIncentives, ExposedStorage, Multicallable {
    using {toDropId} for DropKey;
    using {hashClaim} for Claim;

    function isClaimed(DropKey memory key, uint256 index) external view returns (bool) {
        bytes32 id = key.toDropId();
        (uint256 word, uint8 bit) = indexToWordBit(index);

        // Load bitmap from storage slot: drop id + 1 + word
        bytes32 slot;
        unchecked {
            slot = bytes32(uint256(id) + 1 + word);
        }
        Bitmap bitmap;
        assembly ("memory-safe") {
            bitmap := sload(slot)
        }

        return bitmap.isSet(bit);
    }

    function isAvailable(DropKey memory key, uint256 index, uint128 amount) external view returns (bool) {
        bytes32 id = key.toDropId();

        (uint256 word, uint8 bit) = indexToWordBit(index);

        // Check if already claimed
        bytes32 bitmapSlot;
        unchecked {
            bitmapSlot = bytes32(uint256(id) + 1 + word);
        }
        Bitmap bitmap;
        assembly ("memory-safe") {
            bitmap := sload(bitmapSlot)
        }
        if (bitmap.isSet(bit)) return false;

        // Load drop state from storage slot: drop id
        DropState dropState;
        assembly ("memory-safe") {
            dropState := sload(id)
        }

        return dropState.getRemaining() >= amount;
    }

    function getRemaining(DropKey memory key) external view returns (uint128) {
        bytes32 id = key.toDropId();

        // Load drop state from storage slot: drop id
        DropState dropState;
        assembly ("memory-safe") {
            dropState := sload(id)
        }

        return dropState.getRemaining();
    }

    function fund(DropKey memory key, uint128 minimum) external returns (uint128 fundedAmount) {
        bytes32 id = key.toDropId();

        // Load drop state from storage slot: drop id
        DropState dropState;
        assembly ("memory-safe") {
            dropState := sload(id)
        }

        uint128 currentFunded = dropState.funded();
        if (currentFunded < minimum) {
            fundedAmount = minimum - currentFunded;
            dropState = dropState.setFunded(minimum);

            // Store updated drop state
            assembly ("memory-safe") {
                sstore(id, dropState)
            }

            SafeTransferLib.safeTransferFrom(key.token, msg.sender, address(this), fundedAmount);
            emit Funded(key, minimum);
        }
    }

    function refund(DropKey memory key) external returns (uint128 refundAmount) {
        if (msg.sender != key.owner) {
            revert DropOwnerOnly();
        }

        bytes32 id = key.toDropId();

        // Load drop state from storage slot: drop id
        DropState dropState;
        assembly ("memory-safe") {
            dropState := sload(id)
        }

        refundAmount = dropState.getRemaining();
        if (refundAmount > 0) {
            // Set funded amount to claimed amount (no remaining funds)
            dropState = dropState.setFunded(dropState.claimed());

            // Store updated drop state
            assembly ("memory-safe") {
                sstore(id, dropState)
            }

            SafeTransferLib.safeTransfer(key.token, key.owner, refundAmount);
        }
        emit Refunded(key, refundAmount);
    }

    function claim(DropKey memory key, Claim memory c, bytes32[] calldata proof) external virtual {
        bytes32 id = key.toDropId();

        // Check that it is not claimed
        (uint256 word, uint8 bit) = indexToWordBit(c.index);
        bytes32 bitmapSlot;
        unchecked {
            bitmapSlot = bytes32(uint256(id) + 1 + word);
        }
        Bitmap bitmap;
        assembly ("memory-safe") {
            bitmap := sload(bitmapSlot)
        }
        if (bitmap.isSet(bit)) revert AlreadyClaimed();

        // Check the proof is valid
        bytes32 leaf = hashClaim(c);
        if (!MerkleProofLib.verify(proof, key.root, leaf)) revert InvalidProof();

        // Load drop state from storage slot: drop id
        DropState dropState;
        assembly ("memory-safe") {
            dropState := sload(id)
        }

        // Check sufficient funds
        uint128 remaining = dropState.getRemaining();
        if (remaining < c.amount) {
            revert InsufficientFunds();
        }

        // Update claimed amount
        dropState = dropState.setClaimed(dropState.claimed() + c.amount);

        // Store updated drop state
        assembly ("memory-safe") {
            sstore(id, dropState)
        }

        // Update claimed bitmap
        bitmap = bitmap.toggle(bit);
        assembly ("memory-safe") {
            sstore(bitmapSlot, bitmap)
        }

        SafeTransferLib.safeTransfer(key.token, c.account, c.amount);
    }
}
