// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

/// @title Mintable ERC20 Interface
/// @notice Minimal mint interface for contracts that mint tokens directly to a recipient.
interface IMintableERC20 {
    /// @notice Mints `amount` tokens to `recipient`.
    /// @param recipient Account receiving the minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address recipient, uint256 amount) external;
}
