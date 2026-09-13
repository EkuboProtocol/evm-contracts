// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {FreeLPTokenMetadata} from "./FreeLPTokenMetadata.sol";
import {FreeLPMetadataPrice} from "./FreeLPMetadataPrice.sol";

/// @notice Text-first, self-contained artwork. Token strings are display data, not identity verification.
library FreeLPMetadata {
    function tokenSvg(uint256 id, PoolKey memory key, int32 lower, int32 upper) internal view returns (string memory) {
        return _svg(id, key, lower, upper, FreeLPTokenMetadata.read(key.token0), FreeLPTokenMetadata.read(key.token1));
    }

    function tokenURI(uint256 id, address core, PoolKey memory key, int32 lower, int32 upper)
        internal
        view
        returns (string memory)
    {
        FreeLPTokenMetadata.Data memory a = FreeLPTokenMetadata.read(key.token0);
        FreeLPTokenMetadata.Data memory b = FreeLPTokenMetadata.read(key.token1);
        string memory image = Base64.encode(bytes(_svg(id, key, lower, upper, a, b)));
        string memory identity = string.concat(
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
                        '{"name":"Liquidity Position #',
                        LibString.toString(id),
                        '","description":"An ownerless liquidity position. Token names and symbols are self-reported on-chain display metadata.",',
                        '"image":"data:image/svg+xml;base64,',
                        image,
                        '","properties":{',
                        identity,
                        _tokenProperties("token0", a),
                        _tokenProperties("token1", b),
                        "}}"
                    )
                )
            )
        );
    }

    function _tokenProperties(string memory prefix, FreeLPTokenMetadata.Data memory token)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            ',"',
            prefix,
            '_symbol":',
            LibString.escapeJSON(token.symbol, true),
            ',"',
            prefix,
            '_name":',
            LibString.escapeJSON(token.name, true),
            ',"',
            prefix,
            '_decimals":',
            token.hasDecimals ? LibString.toString(token.decimals) : "null"
        );
    }

    function _svg(
        uint256 id,
        PoolKey memory key,
        int32 lower,
        int32 upper,
        FreeLPTokenMetadata.Data memory a,
        FreeLPTokenMetadata.Data memory b
    ) private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="640" viewBox="0 0 640 640">',
            '<rect width="640" height="640" fill="#fff"/>',
            _heading(id, a, b),
            _artwork(uint256(PoolId.unwrap(key.toPoolId())) % 180),
            '<g font-family="Arial,Helvetica,sans-serif" fill="#153f65"><text x="32" y="277" font-size="22">',
            key.config.isStableswap() ? "Stableswap" : "Concentrated liquidity",
            "</text></g>",
            _range(lower, upper, a, b),
            '<g font-family="Arial,Helvetica,sans-serif" fill="#153f65" font-size="16"><text x="32" y="557">',
            LibString.toHexString(key.token0),
            '</text><text x="32" y="595">',
            LibString.toHexString(key.token1),
            "</text></g></svg>"
        );
    }

    function _heading(uint256 id, FreeLPTokenMetadata.Data memory a, FreeLPTokenMetadata.Data memory b)
        private
        pure
        returns (string memory)
    {
        string memory pair = string.concat(
            FreeLPTokenMetadata.shorten(a.symbol, 8), " / ", FreeLPTokenMetadata.shorten(b.symbol, 8)
        );
        return string.concat(
            '<g font-family="Arial,Helvetica,sans-serif" fill="#153f65">',
            '<text x="32" y="46" font-size="24">Free LP</text><text x="608" y="46" text-anchor="end" font-size="20">#',
            LibString.toString(id),
            '</text><text x="32" y="105" font-size="',
            LibString.runeCount(pair) > 12 ? "28" : "44",
            '">',
            LibString.escapeHTML(pair),
            '</text><text x="32" y="147" font-size="22">',
            LibString.escapeHTML(FreeLPTokenMetadata.shorten(a.name, 24)),
            '</text><text x="32" y="180" font-size="22">',
            LibString.escapeHTML(FreeLPTokenMetadata.shorten(b.name, 24)),
            '</text><text x="32" y="217" font-size="18">',
            a.hasDecimals ? LibString.toString(a.decimals) : "Unknown",
            " / ",
            b.hasDecimals ? LibString.toString(b.decimals) : "unknown",
            " decimals</text></g>"
        );
    }

    function _range(int32 lower, int32 upper, FreeLPTokenMetadata.Data memory a, FreeLPTokenMetadata.Data memory b)
        private
        pure
        returns (string memory)
    {
        bool prices = a.hasDecimals && b.hasDecimals;
        string memory unit = prices
            ? string.concat(FreeLPTokenMetadata.shorten(b.symbol, 8), " per ", FreeLPTokenMetadata.shorten(a.symbol, 8))
            : "Decimals unavailable";
        return string.concat(
            '<path d="M32 365H608" stroke="#2878a0"/><g font-family="Arial,Helvetica,sans-serif" fill="#153f65">',
            '<text x="32" y="405" font-size="24">',
            prices ? "Price range" : "Tick range",
            "</text>",
            '<text x="608" y="405" text-anchor="end" font-size="18">',
            LibString.escapeHTML(unit),
            "</text>",
            '<text x="32" y="438" font-size="18">Minimum</text><text x="608" y="438" text-anchor="end" font-size="18">Maximum</text>',
            '<text x="32" y="477" font-size="32">',
            _bound(lower, a, b),
            "</text>",
            '<text x="608" y="477" text-anchor="end" font-size="32">',
            _bound(upper, a, b),
            "</text>",
            '<text x="32" y="514" font-size="14">Raw ticks: ',
            LibString.toString(int256(lower)),
            " to ",
            LibString.toString(int256(upper)),
            "</text></g>"
        );
    }

    function _bound(int32 tick, FreeLPTokenMetadata.Data memory a, FreeLPTokenMetadata.Data memory b)
        private
        pure
        returns (string memory)
    {
        if (!a.hasDecimals || !b.hasDecimals) return LibString.toString(int256(tick));
        return string.concat("~ ", FreeLPMetadataPrice.format(tick, a.decimals, b.decimals));
    }

    function _artwork(uint256 rotation) private pure returns (string memory) {
        return string.concat(
            '<defs><pattern id="ripples" width="180" height="180" patternUnits="userSpaceOnUse" x="430" y="185">',
            '<g fill="none" stroke="#2878a0" stroke-width="1">',
            _ripples(),
            "</g></pattern>",
            '<clipPath id="disc"><circle cx="520" cy="272" r="72"/></clipPath></defs>',
            '<g clip-path="url(#disc)"><circle cx="520" cy="272" r="72" fill="#eff7fa"/><g transform="rotate(',
            LibString.toString(rotation),
            ' 520 272)"><circle cx="488" cy="272" r="66" fill="#bde4ee"/>',
            '<circle cx="552" cy="272" r="66" fill="#bde4ee"/><path d="M520 212 A66 66 0 0 1 520 332 A66 66 0 0 1 520 212Z" fill="#eac17b"/>',
            '<rect x="430" y="182" width="180" height="180" fill="url(#ripples)"/></g></g><circle cx="520" cy="272" r="72" fill="none" stroke="#153f65" stroke-width="2"/>'
        );
    }

    function _ripples() private pure returns (string memory result) {
        for (uint256 radius = 12; radius <= 84; radius += 12) {
            string memory r = LibString.toString(radius);
            result =
                string.concat(result, '<circle cx="58" cy="87" r="', r, '"/><circle cx="122" cy="87" r="', r, '"/>');
        }
    }
}
