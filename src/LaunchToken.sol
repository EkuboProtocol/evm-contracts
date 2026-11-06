// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @dev True when `packed` is the canonical `LibString.packOne` word of a 1 to 31 byte string: byte 0 is the length,
/// bytes `1..length` are the content and every byte after the content is zero. The empty string (`bytes32(0)`) is
/// not canonical. Canonical words and strings correspond one to one, so `unpackOne` followed by `packOne` returns
/// the same word and one name can never produce two token addresses.
function isCanonicalPackedString(bytes32 packed) pure returns (bool) {
    uint256 length = uint256(packed) >> 248;
    // A shift of 256 or more yields zero in Solidity, so a 31-byte content needs no special case.
    return length != 0 && length <= 31 && (uint256(packed) << (8 * (length + 1))) == 0;
}

/// @title Launch token
/// @notice Fixed-supply ERC-20 created by the zero-seed launch extension. The name and symbol are canonical
/// `LibString.packOne` words held as immutables, decimals are 18, and the whole supply is minted once by the
/// deploying extension; no path can mint afterwards.
contract LaunchToken is ERC20 {
    /// @notice Thrown when anyone but the deployer calls `mint`, or when a supply already exists.
    error MintClosed();

    address private immutable _LAUNCH;
    bytes32 private immutable _NAME;
    bytes32 private immutable _SYMBOL;

    /// @param name_ Canonical packed name; the deployer validates it (`isCanonicalPackedString`).
    /// @param symbol_ Canonical packed symbol, validated the same way.
    constructor(bytes32 name_, bytes32 symbol_) {
        _LAUNCH = msg.sender;
        _NAME = name_;
        _SYMBOL = symbol_;
    }

    /// @notice Mints the whole supply: `amount` to `recipient` and `remainder` to the zero address. Deployer only,
    /// and only while nothing has been minted, so the supply is fixed by the first call.
    function mint(address recipient, uint128 amount, uint128 remainder) external {
        if (msg.sender != _LAUNCH || totalSupply() != 0) revert MintClosed();
        _mint(recipient, amount);
        if (remainder != 0) _mint(address(0), remainder);
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_NAME);
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_SYMBOL);
    }
}
