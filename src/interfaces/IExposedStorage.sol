// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

/// @title IExposedStorage
/// @notice Interface for exposing contract storage via view methods
/// @dev This interface provides a way to access specific pieces of state in the inheriting contract.
///      It serves as a workaround in the absence of EIP-2330 (https://eips.ethereum.org/EIPS/eip-2330)
///      which would provide native support for exposing contract storage.
interface IExposedStorage {
    /// @notice Loads storage slots from the contract's persistent storage
    /// @dev Reads each 32-byte slot specified in the calldata (after the function selector) from storage
    ///      and returns all the loaded values concatenated together.
    function sload() external view;

    /// @notice Loads storage slots from the contract's transient storage
    /// @dev Reads each 32-byte slot specified in the calldata (after the function selector) from transient storage
    ///      and returns all the loaded values concatenated together. Transient storage is cleared at the end
    ///      of each transaction.
    function tload() external view;
}
