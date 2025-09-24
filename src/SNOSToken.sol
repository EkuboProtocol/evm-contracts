// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

contract SNOSToken is ERC20 {
    bytes32 private immutable _name;
    bytes32 private immutable constantNameHash;
    bytes32 private immutable _symbol;

    constructor(bytes32 __symbol, bytes32 __name, uint256 totalSupply) {
        _name = __name;
        _symbol = __symbol;

        constantNameHash = keccak256(bytes(LibString.unpackOne(_name)));

        _mint(msg.sender, totalSupply);
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_name);
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_symbol);
    }

    function _constantNameHash() internal view override returns (bytes32 result) {
        result = constantNameHash;
    }
}
