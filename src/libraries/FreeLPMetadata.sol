// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";

/// @notice Self-contained monochrome NFT metadata. Address labels avoid untrusted ERC20 metadata calls.
library FreeLPMetadata {
    function tokenURI(uint256 id, address core, PoolKey memory key, int32 lower, int32 upper)
        internal
        view
        returns (string memory)
    {
        string memory title = string.concat("Liquidity Position #", LibString.toString(id));
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320" viewBox="0 0 640 320">',
            '<rect width="640" height="320" fill="white"/><g fill="black" font-family="monospace" font-size="16">',
            '<text x="24" y="40">',
            title,
            '</text><text x="24" y="90">',
            LibString.toHexString(key.token0),
            '</text><text x="24" y="120">',
            LibString.toHexString(key.token1),
            '</text><text x="24" y="175">Ticks: ',
            LibString.toString(int256(lower)),
            " to ",
            LibString.toString(int256(upper)),
            '</text><text x="24" y="215">Chain: ',
            LibString.toString(block.chainid),
            "</text></g></svg>"
        );
        string memory attributes = string.concat(
            _attribute("token0", LibString.toHexString(key.token0)),
            ",",
            _attribute("token1", LibString.toHexString(key.token1)),
            ",",
            _attribute("core", LibString.toHexString(core)),
            ",",
            _attribute("config", LibString.toHexString(uint256(PoolConfig.unwrap(key.config)), 32)),
            ",",
            _attribute("tick_lower", LibString.toString(int256(lower))),
            ",",
            _attribute("tick_upper", LibString.toString(int256(upper)))
        );
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        title,
                        '","description":"An ownerless liquidity position. All metadata is generated on chain.",',
                        '"image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(svg)),
                        '","attributes":[',
                        attributes,
                        "]}"
                    )
                )
            )
        );
    }

    function _attribute(string memory trait, string memory value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', trait, '","value":"', value, '"}');
    }
}
