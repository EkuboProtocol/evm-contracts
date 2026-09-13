// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";

/// @notice Self-contained pool ripple artwork. Address labels avoid untrusted ERC20 metadata calls.
library FreeLPMetadata {
    function tokenSvg(uint256 id, PoolKey memory key, int32 lower, int32 upper) internal pure returns (string memory) {
        // Every position in a pool shares its visual identity, just as it shares the stored PoolKey.
        uint256 rotation = uint256(PoolId.unwrap(key.toPoolId())) % 180;
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="640" viewBox="0 0 640 640">',
            '<rect width="640" height="640" fill="#fff"/>',
            '<g font-family="Arial,Helvetica,sans-serif" fill="#153f65">',
            '<text x="32" y="51" font-size="28">Free LP</text>',
            '<text x="608" y="49" text-anchor="end" font-size="18">#',
            LibString.toString(id),
            "</text></g>",
            '<defs><pattern id="ripples" width="640" height="640" patternUnits="userSpaceOnUse">',
            '<g fill="none" stroke="#2878a0" stroke-width="2">',
            _ripples(),
            "</g></pattern>",
            '<clipPath id="disc"><circle cx="320" cy="270" r="172"/></clipPath></defs>',
            '<g clip-path="url(#disc)"><circle cx="320" cy="270" r="172" fill="#eff7fa"/>',
            '<g transform="rotate(',
            LibString.toString(rotation),
            ' 320 270)">',
            '<circle cx="245" cy="270" r="156" fill="#bde4ee"/>',
            '<circle cx="395" cy="270" r="156" fill="#bde4ee"/>',
            '<path d="M320 133 A156 156 0 0 1 320 407 A156 156 0 0 1 320 133Z" fill="#eac17b"/>',
            '<rect x="60" y="50" width="520" height="440" fill="url(#ripples)"/>',
            '</g></g><circle cx="320" cy="270" r="172" fill="none" stroke="#153f65" stroke-width="2"/>',
            '<g font-family="Arial,Helvetica,sans-serif" fill="#153f65">',
            '<text x="32" y="491" font-size="17">',
            key.config.isStableswap() ? "Stableswap" : "Concentrated liquidity",
            '</text><path d="M32 518H608M32 511V525M608 511V525" stroke="#2878a0" fill="none"/>',
            '<text x="32" y="548" font-size="16">',
            LibString.toString(int256(lower)),
            '</text><text x="608" y="548" text-anchor="end" font-size="16">',
            LibString.toString(int256(upper)),
            '</text><text x="32" y="587" font-size="14">',
            LibString.toHexString(key.token0),
            '</text><text x="32" y="613" font-size="14">',
            LibString.toHexString(key.token1),
            "</text></g></svg>"
        );
    }

    function _ripples() private pure returns (string memory result) {
        for (uint256 radius = 24; radius <= 192; radius += 24) {
            string memory r = LibString.toString(radius);
            result =
                string.concat(result, '<circle cx="245" cy="270" r="', r, '"/><circle cx="395" cy="270" r="', r, '"/>');
        }
    }

    function tokenURI(uint256 id, address core, PoolKey memory key, int32 lower, int32 upper)
        internal
        view
        returns (string memory)
    {
        string memory title = string.concat("Liquidity Position #", LibString.toString(id));
        string memory svg = tokenSvg(id, key, lower, upper);
        string memory properties = string.concat(
            '"token0":"',
            LibString.toHexString(key.token0),
            '","token1":"',
            LibString.toHexString(key.token1),
            '","core":"',
            LibString.toHexString(core),
            '","chain":"',
            LibString.toString(block.chainid),
            '","config":"',
            LibString.toHexString(uint256(PoolConfig.unwrap(key.config)), 32),
            '","tick_lower":"',
            LibString.toString(int256(lower)),
            '","tick_upper":"',
            LibString.toString(int256(upper)),
            '"'
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
                        '","properties":{',
                        properties,
                        "}}"
                    )
                )
            )
        );
    }
}
