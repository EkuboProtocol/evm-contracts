// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Bitmap} from "./types/bitmap.sol";
import {DropKey} from "./types/dropKey.sol";
import {ClaimKey} from "./types/claimKey.sol";
import {DropState} from "./types/dropState.sol";
import {IIncentives} from "./interfaces/IIncentives.sol";
import {IncentivesLib} from "./libraries/IncentivesLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

/// @author Moody Salem
/// @notice A singleton contract for making many airdrops
contract Incentives is IIncentives, ExposedStorage, Multicallable {
    /// @inheritdoc IIncentives
    function fund(DropKey memory key, uint128 minimum) external override returns (uint128 fundedAmount) {
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

    /// @inheritdoc IIncentives
    function refund(DropKey memory key) external override returns (uint128 refundAmount) {
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

    /// @inheritdoc IIncentives
    function claim(DropKey memory key, ClaimKey memory c, bytes32[] calldata proof) external override {
        bytes32 id = key.toDropId();

        // Check that it is not claimed
        (uint256 word, uint8 bit) = IncentivesLib.claimIndexToStorageIndex(c.index);
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
        bytes32 leaf = c.toClaimId();
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
