// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {DropKey} from "../types/dropKey.sol";
import {ClaimKey} from "../types/claimKey.sol";
import {IExposedStorage} from "./IExposedStorage.sol";

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
    function claim(DropKey memory key, ClaimKey memory c, bytes32[] calldata proof) external;
}
