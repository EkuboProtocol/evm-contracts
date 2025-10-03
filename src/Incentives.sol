// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Bitmap} from "./types/bitmap.sol";
import {DropKey} from "./types/dropKey.sol";
import {ClaimKey} from "./types/claimKey.sol";
import {DropState} from "./types/dropState.sol";
import {IIncentives} from "./interfaces/IIncentives.sol";
import {IncentivesLib} from "./libraries/IncentivesLib.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";

/// @author Moody Salem
/// @notice A singleton contract for making many airdrops
contract Incentives is IIncentives, ExposedStorage, Multicallable, BaseLocker, UsesCore {
    using FlashAccountantLib for *;

    /// @notice Constructs the Incentives contract
    /// @param core The core contract instance
    constructor(ICore core) BaseLocker(core) UsesCore(core) {}

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

            lock(abi.encode(bytes1(0x01), msg.sender, key.token, fundedAmount));
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

            lock(abi.encode(bytes1(0x02), key.token, key.owner, refundAmount));
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

        lock(abi.encode(bytes1(0x03), key.token, c.account, c.amount));
    }

    /// @notice Sentinel address used as the second token in saved balances
    /// @dev This address is always greater than any real token address
    address private constant SENTINEL = address(type(uint160).max);

    /// @notice Thrown when an unexpected call type is received
    error UnexpectedCallType();

    /// @notice Handles lock callback data for incentives operations
    /// @dev Internal function that processes different types of incentives operations
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];

        if (callType == bytes1(0x01)) {
            // fund: accept payment from funder, then save in Core
            (, address funder, address token, uint128 amount) = abi.decode(data, (bytes1, address, address, uint128));

            // Handle native token differently
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
            } else {
                ACCOUNTANT.payFrom(funder, token, amount);
            }

            // Save the tokens in Core (positive delta increases debt back to zero)
            CORE.updateSavedBalances(token, SENTINEL, bytes32(0), int256(uint256(amount)), 0);
        } else if (callType == bytes1(0x02)) {
            // refund: load from Core, then withdraw to owner
            (, address token, address recipient, uint128 amount) = abi.decode(data, (bytes1, address, address, uint128));
            // Load the tokens from Core (negative delta reduces debt)
            CORE.updateSavedBalances(token, SENTINEL, bytes32(0), -int256(uint256(amount)), 0);
            ACCOUNTANT.withdraw(token, recipient, amount);
        } else if (callType == bytes1(0x03)) {
            // claim: load from Core, then withdraw to claimant
            (, address token, address recipient, uint128 amount) = abi.decode(data, (bytes1, address, address, uint128));
            // Load the tokens from Core (negative delta reduces debt)
            CORE.updateSavedBalances(token, SENTINEL, bytes32(0), -int256(uint256(amount)), 0);
            ACCOUNTANT.withdraw(token, recipient, amount);
        } else {
            revert UnexpectedCallType();
        }
    }
}
