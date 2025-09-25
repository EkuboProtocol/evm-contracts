// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title Simple Token
/// @notice Simple ERC20 token that mints the entire total supply to the sender
contract SimpleToken is ERC20 {
    bytes32 private immutable SYMBOL_PACKED;
    bytes32 private immutable NAME_PACKED;
    bytes32 private immutable CONSTANT_NAME_HASH;

    constructor(bytes32 symbolPacked, bytes32 namePacked, uint256 totalSupply) {
        SYMBOL_PACKED = symbolPacked;
        NAME_PACKED = namePacked;
        CONSTANT_NAME_HASH = keccak256(bytes(LibString.unpackOne(NAME_PACKED)));

        _mint(msg.sender, totalSupply);
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory) {
        return LibString.unpackOne(NAME_PACKED);
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(SYMBOL_PACKED);
    }

    function _constantNameHash() internal view override returns (bytes32 result) {
        result = CONSTANT_NAME_HASH;
    }
}
