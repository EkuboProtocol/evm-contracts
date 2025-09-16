// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @notice NFT contract where tokens can be minted and burned freely, and the owner can change the metadata
abstract contract BaseNonfungibleToken is Ownable, ERC721 {
    error NotUnauthorizedForToken(address caller, uint256 id);

    string private _name;
    string private _symbol;
    string public baseUrl;

    constructor(address owner) {
        _initializeOwner(owner);
    }

    function setMetadata(string memory newName, string memory newSymbol, string memory newBaseUrl) external onlyOwner {
        _name = newName;
        _symbol = newSymbol;
        baseUrl = newBaseUrl;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return string(abi.encodePacked(baseUrl, LibString.toString(id)));
    }

    modifier authorizedForNft(uint256 id) {
        if (!_isApprovedOrOwner(msg.sender, id)) {
            revert NotUnauthorizedForToken(msg.sender, id);
        }
        _;
    }

    function saltToId(address minter, bytes32 salt) public view returns (uint256 result) {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, minter)
            mstore(add(free, 32), salt)
            mstore(add(free, 64), chainid())
            mstore(add(free, 96), address())

            result := shr(128, keccak256(free, 128))
        }
    }

    function mint() public payable returns (uint256 id) {
        // generates a pseudorandom salt
        // note this can have encounter conflicts if a sender sends two identical transactions in the same block
        // that happen to consume exactly the same amount of gas
        bytes32 salt;
        assembly ("memory-safe") {
            mstore(0, prevrandao())
            mstore(32, gas())
            salt := keccak256(0, 64)
        }
        id = mint(salt);
    }

    // Mints an NFT for the caller with the ID given by shr(192, keccak256(minter, salt))
    // This prevents us from having to store a counter of how many were minted
    function mint(bytes32 salt) public payable returns (uint256 id) {
        id = saltToId(msg.sender, salt);
        _mint(msg.sender, id);
    }

    // Can be used to refund some gas after the NFT is no longer needed.
    // The NFT ID may be re-minted by the original minter after it is burned by re-using the salt.
    function burn(uint256 id) external payable authorizedForNft(id) {
        _burn(id);
    }
}
