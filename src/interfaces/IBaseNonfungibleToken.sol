// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

/// @title Base Nonfungible Token Interface
/// @notice Interface for the base NFT functionality used by Positions and Orders contracts
/// @dev Defines the essential NFT functions needed by other contracts in the system
interface IBaseNonfungibleToken {
    function setMetadata(string memory newName, string memory newSymbol, string memory newBaseUrl) external;

    // BaseNonfungibleToken specific functions
    /// @notice Converts a minter address and salt to a token ID
    /// @param minter The minter address
    /// @param salt The salt value
    /// @return result The resulting token ID
    function saltToId(address minter, bytes32 salt) external view returns (uint256 result);

    /// @notice Mints a new token with a random salt
    /// @return id The minted token ID
    function mint() external payable returns (uint256 id);

    /// @notice Mints a new token with a specific salt
    /// @param salt The salt for deterministic ID generation
    /// @return id The minted token ID
    function mint(bytes32 salt) external payable returns (uint256 id);

    /// @notice Burns a token (only authorized addresses)
    /// @param id The token ID to burn
    function burn(uint256 id) external payable;
}
