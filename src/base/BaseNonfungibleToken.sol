// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {IBaseNonfungibleToken} from "../interfaces/IBaseNonfungibleToken.sol";

/// @title Base Nonfungible Token
/// @notice Abstract NFT contract where tokens can be minted and burned freely, and the owner can change the metadata
/// @dev This contract provides a base implementation for NFTs with deterministic ID generation based on minter and salt.
///      Token IDs are generated using keccak256(minter, salt, chainid, contract_address) to ensure uniqueness.
///      The contract allows free minting and burning, with metadata management restricted to the owner.
abstract contract BaseNonfungibleToken is IBaseNonfungibleToken, Ownable, ERC721 {
    /// @notice Thrown when a caller is not authorized to perform an action on a specific token
    /// @param caller The address that attempted the unauthorized action
    /// @param id The token ID for which authorization was required
    error NotUnauthorizedForToken(address caller, uint256 id);

    /// @dev The name of the NFT collection
    string private _name;

    /// @dev The symbol of the NFT collection
    string private _symbol;

    /// @notice The base URL used for constructing token URIs
    /// @dev Token URIs are constructed by concatenating this base URL with the token ID
    string public baseUrl;

    /// @notice Initializes the contract with the specified owner
    /// @param owner The address that will be set as the owner of the contract
    constructor(address owner) {
        _initializeOwner(owner);
    }

    /// @notice Updates the metadata for the NFT collection
    /// @dev Only the contract owner can call this function
    /// @param newName The new name for the NFT collection
    /// @param newSymbol The new symbol for the NFT collection
    /// @param newBaseUrl The new base URL for token metadata
    function setMetadata(string memory newName, string memory newSymbol, string memory newBaseUrl) external onlyOwner {
        _name = newName;
        _symbol = newSymbol;
        baseUrl = newBaseUrl;
    }

    /// @notice Returns the name of the NFT collection
    /// @return The name of the collection
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the NFT collection
    /// @return The symbol of the collection
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the URI for a given token ID
    /// @dev Constructs the URI by concatenating the base URL with the token ID.
    ///      If baseUrl is empty, returns just the stringified token ID.
    /// @param id The token ID to get the URI for
    /// @return The complete URI for the token
    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return string(abi.encodePacked(baseUrl, LibString.toString(id)));
    }

    /// @notice Modifier to ensure the caller is authorized to perform actions on a specific token
    /// @dev Checks if the caller is the owner or approved for the token
    /// @param id The token ID to check authorization for
    modifier authorizedForNft(uint256 id) {
        if (!_isApprovedOrOwner(msg.sender, id)) {
            revert NotUnauthorizedForToken(msg.sender, id);
        }
        _;
    }

    /// @inheritdoc IBaseNonfungibleToken
    /// @dev Uses keccak256 hash of minter, salt, chain ID, and contract address to generate unique IDs.
    ///      IDs are deterministic per (minter, salt, chainId, contract) tuple; the same pair on a
    ///      different chain or contract yields a different ID.
    function saltToId(address minter, bytes32 salt) public view returns (uint256 result) {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, minter)
            mstore(add(free, 32), salt)
            mstore(add(free, 64), chainid())
            mstore(add(free, 96), address())

            result := keccak256(free, 128)
        }
    }

    /// @inheritdoc IBaseNonfungibleToken
    /// @dev Generates a salt using prevrandao() and gas() for pseudorandomness.
    ///      Note: This can encounter conflicts if a sender sends two identical transactions
    ///      in the same block that consume exactly the same amount of gas.
    ///      No fees are collected; any msg.value sent is ignored.
    function mint() public payable returns (uint256 id) {
        bytes32 salt;
        assembly ("memory-safe") {
            mstore(0, prevrandao())
            mstore(32, gas())
            salt := keccak256(0, 64)
        }
        id = mint(salt);
    }

    /// @inheritdoc IBaseNonfungibleToken
    /// @dev The token ID is generated using saltToId(msg.sender, salt). This prevents the need
    ///      to store a counter of how many tokens were minted, as IDs are deterministic.
    ///      No fees are collected; any msg.value sent is ignored.
    function mint(bytes32 salt) public payable returns (uint256 id) {
        id = saltToId(msg.sender, salt);
        _mint(msg.sender, id);
    }

    /// @inheritdoc IBaseNonfungibleToken
    /// @dev Can be used to refund some gas after the NFT is no longer needed.
    ///      The same ID can be recreated by the original minter by reusing the salt.
    ///      Only the token owner or approved addresses can burn the token.
    ///      No fees are collected; any msg.value sent is ignored.
    function burn(uint256 id) external payable authorizedForNft(id) {
        _burn(id);
    }
}
