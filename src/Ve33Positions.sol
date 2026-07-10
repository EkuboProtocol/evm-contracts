// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseVe33Positions} from "./base/BaseVe33Positions.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";

/// @notice ERC721 position manager for Ve33 liquidity positions.
contract Ve33Positions is BaseVe33Positions {
    /// @notice Creates the Ve33 position NFT manager.
    /// @param core Ekubo Core contract used for locks and position updates.
    /// @param ve33 Ve33 extension whose pools are supported.
    /// @param owner Owner allowed to set collection metadata.
    constructor(ICore core, Ve33 ve33, address owner) BaseVe33Positions(core, ve33, owner) {}
}
