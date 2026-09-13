// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {LibString} from "solady/utils/LibString.sol";

/// @notice Best-effort display data, with bounded gas, returndata, and valid XML-safe UTF-8.
library FreeLPTokenMetadata {
    struct Data {
        string symbol;
        string name;
        uint8 decimals;
        bool hasDecimals;
    }
    uint256 private constant RETURN_LIMIT = 320;

    function read(address token) internal view returns (Data memory m) {
        if (token == address(0)) return _native();
        m.symbol = _text(token, 0x95d89b41, 32, LibString.slice(LibString.toHexString(token), 0, 8));
        m.name = _text(token, 0x06fdde03, 96, "Unknown token");
        bytes memory value = _call(token, 0x313ce567);
        if (value.length == 32) {
            uint256 decimals;
            assembly ("memory-safe") { decimals := mload(add(value, 32)) }
            if (decimals <= 255) {
                m.decimals = uint8(decimals);
                m.hasDecimals = true;
            }
        }
    }

    function _native() private view returns (Data memory m) {
        (m.symbol, m.name, m.hasDecimals) = _nativeNames(block.chainid);
        if (m.hasDecimals) m.decimals = 18;
    }

    function _nativeNames(uint256 chain) private pure returns (string memory, string memory, bool) {
        if (chain == 56) return ("BNB", "BNB", true);
        if (chain == 137) return ("POL", "Polygon Ecosystem Token", true);
        if (chain == 100) return ("xDAI", "xDAI", true);
        if (chain == 143) return ("MON", "Monad", true);
        if (chain == 43114) return ("AVAX", "Avalanche", true);
        if (_etherChain(chain)) return ("ETH", "Ether", true);
        return ("NATIVE", "Native currency", false);
    }

    function _etherChain(uint256 chain) private pure returns (bool) {
        return
            chain == 1 || chain == 10 || chain == 8453 || chain == 42161 || chain == 130 || chain == 57073
                || chain == 4663;
    }

    function _call(address token, bytes4 selector) private view returns (bytes memory data) {
        data = new bytes(RETURN_LIMIT);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(add(data, 32), selector)
            ok := staticcall(30000, token, add(data, 32), 4, add(data, 32), RETURN_LIMIT)
            size := returndatasize()
        }
        if (!ok || size > RETURN_LIMIT) return new bytes(0);
        assembly ("memory-safe") { mstore(data, size) }
    }

    function _text(address token, bytes4 selector, uint256 limit, string memory fallback_)
        private
        view
        returns (string memory)
    {
        bytes memory data = _call(token, selector);
        (uint256 start, uint256 length) = _stringBounds(data);
        if (length == 0) return fallback_;
        return _clean(data, start, length, limit, fallback_);
    }

    function _stringBounds(bytes memory data) private pure returns (uint256 start, uint256 length) {
        if (data.length == 32) {
            while (length < 32 && data[length] != 0) ++length;
        } else if (data.length >= 64) {
            uint256 offset;
            assembly ("memory-safe") {
                offset := mload(add(data, 32))
                length := mload(add(data, 64))
            }
            if (offset != 32 || length > data.length - 64) return (0, 0);
            start = 64;
        }
    }

    function _clean(bytes memory data, uint256 start, uint256 length, uint256 limit, string memory fallback_)
        private
        pure
        returns (string memory)
    {
        bytes memory out = new bytes(limit);
        uint256 written;
        uint256 i;
        bool visible;
        while (i < length && written < limit) {
            uint256 width = _width(data, start + i, start + length);
            if (width == 0) {
                out[written++] = "?";
                ++i;
                visible = true;
            } else {
                if (written + width > limit) break;
                if (data[start + i] != 0x20) visible = true;
                for (uint256 j; j < width; ++j) {
                    out[written++] = data[start + i + j];
                }
                i += width;
            }
        }
        if (!visible) return fallback_;
        assembly ("memory-safe") { mstore(out, written) }
        return string(out);
    }

    function _width(bytes memory data, uint256 i, uint256 end) private pure returns (uint256 width) {
        uint8 first = uint8(data[i]);
        if (first < 0x80) return first >= 0x20 && first != 0x7f ? 1 : 0;
        uint256 code;
        uint256 minimum;
        (width, code, minimum) = _leadingByte(first);
        if (width == 0 || i + width > end) return 0;
        for (uint256 j = 1; j < width; ++j) {
            uint8 next = uint8(data[i + j]);
            if (next < 0x80 || next > 0xbf) return 0;
            code = (code << 6) | (next & 0x3f);
        }
        if (code < minimum || !_displayCodePoint(code)) return 0;
    }

    function _leadingByte(uint8 first) private pure returns (uint256 width, uint256 code, uint256 minimum) {
        if (first >= 0xc2 && first <= 0xdf) {
            width = 2;
            code = first & 0x1f;
            minimum = 0x80;
        } else if (first >= 0xe0 && first <= 0xef) {
            width = 3;
            code = first & 0x0f;
            minimum = 0x800;
        } else if (first >= 0xf0 && first <= 0xf4) {
            width = 4;
            code = first & 0x07;
            minimum = 0x10000;
        } else {
            return (0, 0, 0);
        }
    }

    function _displayCodePoint(uint256 code) private pure returns (bool) {
        if (code < 0xa0 || code > 0x10ffff) return false;
        if (code >= 0xd800 && code <= 0xdfff) return false;
        if ((code & 0xffff) >= 0xfffe) return false;
        if (code >= 0x202a && code <= 0x202e) return false;
        return code < 0x2066 || code > 0x2069;
    }

    /// @dev Input is already cleaned by read(); limits count code points, never partial bytes.
    function shorten(string memory value, uint256 limit) internal pure returns (string memory) {
        if (LibString.runeCount(value) <= limit) return value;
        bytes memory data = bytes(value);
        uint256 i;
        for (uint256 count; count < limit - 1; ++count) {
            uint8 c = uint8(data[i]);
            i += c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1;
        }
        return string.concat(LibString.slice(value, 0, i), unicode"…");
    }
}
