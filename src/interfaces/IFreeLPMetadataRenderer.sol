// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../types/poolKey.sol";

interface IFreeLPMetadataRenderer {
    function tokenURI(uint256 id, address core, PoolKey memory key, int32 lower, int32 upper)
        external
        view
        returns (string memory);
}
