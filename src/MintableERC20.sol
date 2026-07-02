// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {IMintableERC20} from "./interfaces/IMintableERC20.sol";

/// @title Mintable ERC20
/// @notice ERC20 with owner-gated minting to arbitrary recipients.
contract MintableERC20 is IMintableERC20, Ownable, ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /// @notice Initializes token metadata and owner.
    /// @param owner Initial owner authorized to mint.
    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param decimals_ ERC20 decimals.
    constructor(address owner, string memory name_, string memory symbol_, uint8 decimals_) {
        _initializeOwner(owner);
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    /// @notice Mints tokens to `recipient`.
    function mint(address recipient, uint256 amount) external onlyOwner {
        _mint(recipient, amount);
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
