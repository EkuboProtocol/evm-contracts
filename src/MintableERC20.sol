// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IMintableERC20} from "./interfaces/IMintableERC20.sol";

/// @title Mintable ERC20
/// @notice ERC20 with owner-gated minting to arbitrary recipients.
contract MintableERC20 is IMintableERC20, Ownable, ERC20 {
    bytes32 private immutable _NAME;
    bytes32 private immutable _SYMBOL;
    uint8 private immutable _DECIMALS;

    /// @notice Thrown when a constructor string cannot be packed into one bytes32 word.
    error PackedStringTooLong();

    /// @notice Initializes token metadata and owner.
    /// @param owner Initial owner authorized to mint.
    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param decimals_ ERC20 decimals.
    constructor(address owner, string memory name_, string memory symbol_, uint8 decimals_) {
        _initializeOwner(owner);
        _NAME = _packConstructorString(name_);
        _SYMBOL = _packConstructorString(symbol_);
        _DECIMALS = decimals_;
    }

    /// @notice Mints tokens to `recipient`.
    function mint(address recipient, uint256 amount) external onlyOwner {
        _mint(recipient, amount);
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_NAME);
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_SYMBOL);
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function _packConstructorString(string memory value) private pure returns (bytes32 packed) {
        packed = LibString.packOne(value);
        if (packed == bytes32(0) && bytes(value).length != 0) revert PackedStringTooLong();
    }
}
