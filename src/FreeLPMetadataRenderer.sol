// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IFreeLPMetadataRenderer} from "./interfaces/IFreeLPMetadataRenderer.sol";
import {FreeLPMetadata} from "./libraries/FreeLPMetadata.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice Stateless on-chain renderer shared by FreeLP deployments; no owner, URI setter or hosted resources.
contract FreeLPMetadataRenderer is IFreeLPMetadataRenderer {
    function tokenURI(uint256 id, address core, PoolKey memory key, int32 lower, int32 upper)
        external
        view
        returns (string memory)
    {
        return FreeLPMetadata.tokenURI(id, core, key, lower, upper);
    }
}
