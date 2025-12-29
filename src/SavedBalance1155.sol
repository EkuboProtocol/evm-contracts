// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC1155} from "solady/tokens/ERC1155.sol";
import {LibString} from "solady/utils/LibString.sol";

import {BaseForwardee} from "./base/BaseForwardee.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {Locker} from "./types/locker.sol";

/// @title Saved Balance ERC1155 Wrapper
/// @notice ERC1155 receipt tokens representing balances saved in Ekubo Core.
/// @dev Minting and burning happens through Core.forward calls so we can update Core's saved balances and
///      supply in a single hop. Token IDs are derived from the underlying token address.
contract SavedBalance1155 is ERC1155, UsesCore, BaseForwardee {
    /// @notice Thrown when the uri function is called for an impossible token ID
    error InvalidTokenId();

    constructor(ICore core) UsesCore(core) BaseForwardee(core) {}

    /// @notice Returns the ERC1155 token id for an underlying token address.
    function tokenId(address token) public pure returns (uint256) {
        return uint256(uint160(token));
    }

    /// @inheritdoc ERC1155
    function uri(uint256 id) public pure override returns (string memory) {
        if (id >= type(uint160).max) {
            revert InvalidTokenId();
        }

        // Simple data URI carrying the underlying token address encoded in hex.
        return string.concat(
            "data:application/json;utf8,{\"token\":\"0x", LibString.toHexStringChecksummed(address(uint160(id))), "\"}"
        );
    }

    /// @notice Handles mint/burn requests forwarded from Core.
    /// @dev Expects abi.encode(address token, address counterparty, int128 amount) as forwarded data.
    ///      Positive amounts save the underlying token and mint the ERC1155 receipt to the specified recipient.
    ///      Negative amounts load the underlying token from saved balances and burn from the specified counterparty (the locker must be approved to spend the token).
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        (address token, address counterparty, int128 amount) = abi.decode(data, (address, address, int128));

        // will revert if token == address(type(uint160)).max
        CORE.updateSavedBalances(token, address(type(uint160).max), bytes32(0), amount, 0);

        uint256 id = tokenId(token);
        if (amount > 0) {
            _mint({to: counterparty, id: id, amount: uint256(uint128(amount)), data: ""});
        } else if (amount < 0) {
            _burn({by: original.addr(), from: counterparty, id: id, amount: uint256(uint128(-amount))});
        }
    }
}
