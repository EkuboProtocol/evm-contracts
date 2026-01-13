// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {LibString} from "solady/utils/LibString.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {Locker} from "./types/locker.sol";

/// @title Saved Balance ERC6909 Wrapper
/// @notice ERC6909 receipt tokens representing balances saved in Ekubo Core.
/// @dev Minting and burning happens through Core.forward calls so we can update Core's saved balances and
///      supply in a single hop. Token IDs are derived from the underlying token address.
contract SavedBalancesWrapper is ERC6909, UsesCore, BaseForwardee {
    /// @notice Thrown when the uri function is called for an impossible token ID
    error InvalidTokenId(uint256 id);

    error InsufficientAllowance();

    /// @notice Allows the given locker to spend a specified amount of tokens for the duration of the transaction
    function temporaryAllowBurn(address locker, uint256 id, uint256 amount) external payable virtual {
        bytes32 slot = EfficientHashLib.hash(uint256(uint160(msg.sender)), uint256(uint160(locker)), id);
        assembly ("memory-safe") {
            tstore(slot, amount)
        }
    }

    /// @dev Burns the allowed amount if it's available, or reverts if not
    function _spendTemporaryBurnAmount(address owner, address locker, uint256 id, uint256 amount) private {
        bytes32 slot = EfficientHashLib.hash(uint256(uint160(owner)), uint256(uint160(locker)), id);
        uint256 allowance;
        assembly ("memory-safe") {
            allowance := tload(slot)
        }
        if (allowance < amount) {
            revert InsufficientPermission();
        }
        assembly ("memory-safe") {
            tstore(slot, sub(allowance, amount))
        }
    }

    constructor(ICore core) UsesCore(core) BaseForwardee(core) {}

    /// @notice Returns the ERC1155 token id for an underlying token address.
    function tokenId(address token) public pure returns (uint256) {
        return uint256(uint160(token));
    }

    /// @notice Returns the token address that is wrapped given the token ID
    function tokenAddress(uint256 id) public pure returns (address) {
        if (id >= type(uint160).max) {
            revert InvalidTokenId(id);
        }
        return address(uint160(id));
    }

    /// @inheritdoc ERC6909
    function name(uint256 id) public view override returns (string memory) {
        return IERC20(tokenAddress(id)).name();
    }

    /// @inheritdoc ERC6909
    function symbol(uint256 id) public view override returns (string memory) {
        return IERC20(tokenAddress(id)).symbol();
    }

    function decimals(uint256 id) public view override returns (uint8) {
        return IERC20(tokenAddress(id)).decimals();
    }

    /// @notice Returns the metadata for the contract.
    function contractURI() public pure returns (string memory) {
        return string.concat(
            "data:application/json;utf8,{\"name\":\"Ekubo Saved Balances\",\"description\":\"Wraps saved balances in Ekubo into ERC6909 tokens\"}"
        );
    }

    /// @inheritdoc ERC6909
    function tokenURI(uint256 id) public pure override returns (string memory) {
        address token = tokenAddress(id);

        // Simple data URI carrying the underlying token address encoded in hex.
        return string.concat("data:application/json;utf8,{\"token\":\"", LibString.toHexStringChecksummed(token), "\"}");
    }

    /// @notice Handles mint/burn requests forwarded from Core.
    /// @dev Expects abi.encode(address token, address counterparty, int128 amount) as forwarded data.
    ///      Positive amounts save the underlying token and mint the ERC1155 receipt to the specified recipient.
    ///      Negative amounts load the underlying token from saved balances and burn from the specified counterparty (the locker must be approved to spend the token).
    /// @return The return value is always empty, i.e. is not used.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        (address token, address counterparty, int128 amount) = abi.decode(data, (address, address, int128));

        // will revert if token == address(type(uint160)).max
        CORE.updateSavedBalances(token, address(type(uint160).max), bytes32(0), amount, 0);

        uint256 id = tokenId(token);
        if (amount > 0) {
            _mint({to: counterparty, id: id, amount: uint256(uint128(amount))});
        } else if (amount < 0) {
            uint256 unsignedAmount = uint256(uint128(-amount));
            _spendTemporaryBurnAmount({owner: counterparty, locker: original.addr(), id: id, amount: unsignedAmount});
            _burn({from: counterparty, id: id, amount: unsignedAmount});
        }
    }
}
