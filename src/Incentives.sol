// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Bitmap} from "./math/bitmap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

/// @author Moody Salem
/// @notice A singleton contract for making many airdrops
contract Incentives is Multicallable {
    /// @notice Emitted each time fund is successfully called
    event Funded(address token, bytes32 root, uint256 amount);

    /// @notice Thrown if the root has already been funded for this token
    error AlreadyFunded();
    /// @notice Thrown if the claim has already happened for the root
    error AlreadyClaimed();
    /// @notice Thrown if the proof does not correspond to the claim in the root
    error InvalidProof();
    /// @notice Thrown if the root does not have enough funds for the claim, or is not funded
    error InsufficientFunds();

    struct Drop {
        uint256 remaining;
        mapping(uint256 => Bitmap) claimed;
    }

    mapping(address token => mapping(bytes32 root => Drop)) private drops;

    // We store this separately because it's only used to prevent double funding
    mapping(address token => mapping(bytes32 root => bool)) public funded;

    function getRemaining(address token, bytes32 root) external view returns (uint256) {
        return drops[token][root].remaining;
    }

    function hashClaim(uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return EfficientHashLib.hash(bytes32(index), bytes32(bytes20(account)), bytes32(amount));
    }

    function isClaimed(address token, bytes32 root, uint256 index) external view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        return drops[token][root].claimed[wordIndex].isSet(uint8(bitIndex));
    }

    function isAvailable(address token, bytes32 root, uint256 index, uint256 amount) external view returns (bool) {
        Drop storage drop = drops[token][root];
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        return drop.claimed[wordIndex].isSet(uint8(bitIndex)) && drop.remaining >= amount;
    }

    function fund(address token, bytes32 root, uint256 amount) external {
        if (funded[token][root]) revert AlreadyFunded();
        drops[token][root].remaining += amount;
        funded[token][root] = true;
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit Funded(token, root, amount);
    }

    function claim(
        address token,
        bytes32 root,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external virtual {
        Drop storage drop = drops[token][root];

        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        Bitmap b = drop.claimed[wordIndex];

        if (b.isSet(uint8(bitIndex))) revert AlreadyClaimed();

        bytes32 leaf = hashClaim(index, account, amount);
        if (!MerkleProofLib.verify(proof, root, leaf)) revert InvalidProof();

        uint256 remaining = drop.remaining;
        if (remaining < amount) {
            revert InsufficientFunds();
        }
        drop.remaining = remaining - amount;
        drop.claimed[wordIndex] = b.toggle(uint8(bitIndex));

        SafeTransferLib.safeTransfer(token, account, amount);
    }
}
