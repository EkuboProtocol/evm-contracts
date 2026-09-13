// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Six-significant-digit, display-only tick prices in token1 per token0.
library FreeLPMetadataPrice {
    int256 private constant LN10_WAD = 2302585092994045684;

    function format(int32 tick, uint8 decimals0, uint8 decimals1) internal pure returns (string memory) {
        int256 logarithm =
            int256(tick) * 999999500000 + (int256(uint256(decimals0)) - int256(uint256(decimals1))) * LN10_WAD;
        int256 exponent = logarithm / LN10_WAD;
        if (logarithm < 0 && logarithm % LN10_WAD != 0) --exponent;
        uint256 significant = uint256(FixedPointMathLib.expWad(logarithm - exponent * LN10_WAD)) / 1e13;
        if (significant >= 1e6) {
            significant /= 10;
            ++exponent;
        }
        string memory raw = LibString.toString(significant);
        if (exponent < -3 || exponent >= 6) return string.concat(_decimal(raw, 1), "e", LibString.toString(exponent));
        if (exponent < 0) return _trim(string.concat("0.", _zeros(uint256(-exponent - 1)), raw));
        return _decimal(raw, uint256(exponent + 1));
    }

    function _decimal(string memory raw, uint256 point) private pure returns (string memory) {
        if (point >= bytes(raw).length) return raw;
        return _trim(string.concat(LibString.slice(raw, 0, point), ".", LibString.slice(raw, point)));
    }

    function _trim(string memory value) private pure returns (string memory) {
        bytes memory data = bytes(value);
        uint256 end = data.length;
        while (end != 0 && data[end - 1] == "0") --end;
        if (end != 0 && data[end - 1] == ".") --end;
        assembly ("memory-safe") { mstore(data, end) }
        return string(data);
    }

    function _zeros(uint256 count) private pure returns (string memory value) {
        for (uint256 i; i < count; ++i) {
            value = string.concat(value, "0");
        }
    }
}
