// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Pure metadata renderer for VeToken ERC721 positions.
library VeTokenMetadata {
    struct Params {
        uint256 id;
        uint128 amount;
        uint64 unlockTime;
        string veSymbol;
        string stakeTokenName;
        string stakeTokenSymbol;
        uint8 stakeTokenDecimals;
        address stakeToken;
    }

    /// @notice Builds the ERC721 metadata data URI for a VeToken position.
    /// @param params Metadata fields and current stake state.
    /// @return Base64 JSON data URI.
    function tokenURI(Params memory params) internal pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(tokenJson(params))));
    }

    /// @notice Builds the raw ERC721 metadata JSON for a VeToken position.
    /// @param params Metadata fields and current stake state.
    /// @return Raw JSON string.
    function tokenJson(Params memory params) internal pure returns (string memory) {
        string memory idString = LibString.toString(params.id);
        string memory tokenName = string.concat(params.veSymbol, " #", idString);
        string memory amountString = formatTokenAmount(params.amount, params.stakeTokenDecimals);
        string memory unlockDate = formatDate(params.unlockTime);
        string memory description = string.concat(
            "Vote-escrowed ",
            params.stakeTokenName,
            " stake. Amount: ",
            amountString,
            " ",
            params.stakeTokenSymbol,
            ". Unlock date: ",
            unlockDate,
            ". Stake token: ",
            LibString.toHexStringChecksummed(params.stakeToken),
            "."
        );
        string memory image = string.concat(
            "data:image/svg+xml;base64,", Base64.encode(bytes(_tokenSvg(params, amountString, unlockDate)))
        );

        return string.concat(
            "{\"name\":",
            LibString.escapeJSON(tokenName, true),
            ",\"description\":",
            LibString.escapeJSON(description, true),
            ",\"image\":",
            LibString.escapeJSON(image, true),
            "}"
        );
    }

    /// @notice Builds the raw SVG image embedded in ERC721 metadata.
    /// @param params Metadata fields and current stake state.
    /// @return Raw SVG string.
    function tokenSvg(Params memory params) internal pure returns (string memory) {
        return
            _tokenSvg(
                params, formatTokenAmount(params.amount, params.stakeTokenDecimals), formatDate(params.unlockTime)
            );
    }

    /// @notice Formats a stake-token amount using token decimals, trimming trailing fractional zeros.
    /// @param amount Raw stake-token amount.
    /// @param decimals Stake-token decimals.
    /// @return Decimal-adjusted amount string.
    function formatTokenAmount(uint256 amount, uint256 decimals) internal pure returns (string memory) {
        string memory digitsString = LibString.toString(amount);
        if (decimals == 0) return digitsString;

        bytes memory digits = bytes(digitsString);
        if (amount == 0) return "0";

        if (digits.length > decimals) {
            uint256 wholeLength = digits.length - decimals;
            uint256 wholeFractionalLength = decimals;
            while (wholeFractionalLength != 0 && digits[wholeLength + wholeFractionalLength - 1] == bytes1("0")) {
                unchecked {
                    --wholeFractionalLength;
                }
            }
            if (wholeFractionalLength == 0) return LibString.slice(digitsString, 0, wholeLength);

            bytes memory wholeResult = new bytes(wholeLength + 1 + wholeFractionalLength);
            for (uint256 i; i < wholeLength;) {
                wholeResult[i] = digits[i];
                unchecked {
                    ++i;
                }
            }
            wholeResult[wholeLength] = bytes1(".");
            for (uint256 i; i < wholeFractionalLength;) {
                wholeResult[wholeLength + 1 + i] = digits[wholeLength + i];
                unchecked {
                    ++i;
                }
            }
            return string(wholeResult);
        }

        uint256 leadingZeros = decimals - digits.length;
        uint256 fractionalLength = digits.length;
        while (fractionalLength != 0 && digits[fractionalLength - 1] == bytes1("0")) {
            unchecked {
                --fractionalLength;
            }
        }
        bytes memory result = new bytes(2 + leadingZeros + fractionalLength);
        result[0] = bytes1("0");
        result[1] = bytes1(".");
        for (uint256 i; i < leadingZeros;) {
            result[2 + i] = bytes1("0");
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < fractionalLength;) {
            result[2 + leadingZeros + i] = digits[i];
            unchecked {
                ++i;
            }
        }
        return string(result);
    }

    /// @notice Formats a timestamp as an English UTC date.
    /// @param timestamp Unix timestamp.
    /// @return Date string like "Jan 1, 2030".
    function formatDate(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = DateTimeLib.timestampToDate(timestamp);
        return string.concat(_monthName(month), " ", LibString.toString(day), ", ", LibString.toString(year));
    }

    function _tokenSvg(Params memory params, string memory amountString, string memory unlockDate)
        private
        pure
        returns (string memory)
    {
        string memory tokenAddress = LibString.toHexStringChecksummed(params.stakeToken);
        bool largeId = params.id > 999_999;
        return string.concat(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 480 480\">",
            "<rect width=\"480\" height=\"480\" fill=\"#101114\"/>",
            "<rect x=\"32\" y=\"32\" width=\"416\" height=\"416\" rx=\"18\" fill=\"#f6f1e8\"/>",
            _svgTitle(params.veSymbol, params.id),
            "<text x=\"56\" y=\"",
            largeId ? "176" : "148",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Stake token</text>",
            "<text x=\"56\" y=\"",
            largeId ? "202" : "176",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"24\">",
            LibString.escapeHTML(params.stakeTokenSymbol),
            "</text>",
            "<text x=\"56\" y=\"",
            largeId ? "250" : "226",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Amount</text>",
            "<text x=\"56\" y=\"",
            largeId ? "276" : "254",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.escapeHTML(amountString),
            "</text>",
            "<text x=\"56\" y=\"",
            largeId ? "324" : "304",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Unlock date</text>",
            "<text x=\"56\" y=\"",
            largeId ? "350" : "332",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.escapeHTML(unlockDate),
            "</text>",
            "<text x=\"56\" y=\"",
            largeId ? "414" : "390",
            "\" fill=\"#101114\" font-family=\"monospace\" font-size=\"14\">",
            LibString.escapeHTML(tokenAddress),
            "</text>",
            "</svg>"
        );
    }

    /// @notice Returns the English abbreviated month name for a 1-indexed month.
    /// @param month Month number.
    /// @return Month abbreviation.
    function _monthName(uint256 month) private pure returns (string memory) {
        if (month == 1) return "Jan";
        if (month == 2) return "Feb";
        if (month == 3) return "Mar";
        if (month == 4) return "Apr";
        if (month == 5) return "May";
        if (month == 6) return "Jun";
        if (month == 7) return "Jul";
        if (month == 8) return "Aug";
        if (month == 9) return "Sep";
        if (month == 10) return "Oct";
        if (month == 11) return "Nov";
        return "Dec";
    }

    function _svgTitle(string memory veSymbol, uint256 id) private pure returns (string memory) {
        if (id <= 999_999) {
            return string.concat(
                "<text x=\"56\" y=\"96\" fill=\"#101114\" font-family=\"monospace\" font-size=\"28\" font-weight=\"700\">",
                LibString.escapeHTML(veSymbol),
                " #",
                LibString.toString(id),
                "</text>"
            );
        }

        return string.concat(
            "<text x=\"56\" y=\"70\" fill=\"#101114\" font-family=\"monospace\" font-size=\"24\" font-weight=\"700\">",
            LibString.escapeHTML(veSymbol),
            " #</text>",
            "<text x=\"56\" y=\"116\" fill=\"#101114\" font-family=\"Apple Color Emoji, Segoe UI Emoji, Noto Color Emoji, sans-serif\" font-size=\"28\">",
            _emojiCode(id),
            "</text>"
        );
    }

    function _emojiCode(uint256 id) private pure returns (string memory) {
        uint256 digest;
        assembly ("memory-safe") {
            mstore(0, id)
            digest := keccak256(0, 32)
        }
        return string.concat(
            _emojiSymbol(digest >> 30),
            _emojiSymbol(digest >> 24),
            _emojiSymbol(digest >> 18),
            _emojiSymbol(digest >> 12),
            _emojiSymbol(digest >> 6),
            _emojiSymbol(digest)
        );
    }

    function _emojiSymbol(uint256 value) private pure returns (string memory) {
        value &= 0x3f;
        if (value == 0) return unicode"🌞";
        if (value == 1) return unicode"🌙";
        if (value == 2) return unicode"⭐";
        if (value == 3) return unicode"🔥";
        if (value == 4) return unicode"💧";
        if (value == 5) return unicode"🌿";
        if (value == 6) return unicode"💎";
        if (value == 7) return unicode"🎲";
        if (value == 8) return unicode"🎯";
        if (value == 9) return unicode"🚀";
        if (value == 10) return unicode"🧭";
        if (value == 11) return unicode"🔒";
        if (value == 12) return unicode"🔑";
        if (value == 13) return unicode"🎵";
        if (value == 14) return unicode"🌀";
        if (value == 15) return unicode"🌊";
        if (value == 16) return unicode"🍀";
        if (value == 17) return unicode"🌈";
        if (value == 18) return unicode"⚡";
        if (value == 19) return unicode"☄️";
        if (value == 20) return unicode"🌋";
        if (value == 21) return unicode"🏔️";
        if (value == 22) return unicode"🏝️";
        if (value == 23) return unicode"🏜️";
        if (value == 24) return unicode"🗿";
        if (value == 25) return unicode"🛡️";
        if (value == 26) return unicode"⚔️";
        if (value == 27) return unicode"🏹";
        if (value == 28) return unicode"🎩";
        if (value == 29) return unicode"👑";
        if (value == 30) return unicode"💼";
        if (value == 31) return unicode"📚";
        if (value == 32) return unicode"🧪";
        if (value == 33) return unicode"🔭";
        if (value == 34) return unicode"🕰️";
        if (value == 35) return unicode"🧲";
        if (value == 36) return unicode"🧱";
        if (value == 37) return unicode"🪙";
        if (value == 38) return unicode"🪄";
        if (value == 39) return unicode"🎨";
        if (value == 40) return unicode"🎻";
        if (value == 41) return unicode"🎹";
        if (value == 42) return unicode"🎬";
        if (value == 43) return unicode"🏆";
        if (value == 44) return unicode"🎖️";
        if (value == 45) return unicode"🏅";
        if (value == 46) return unicode"🏁";
        if (value == 47) return unicode"🧩";
        if (value == 48) return unicode"🎮";
        if (value == 49) return unicode"🕹️";
        if (value == 50) return unicode"📡";
        if (value == 51) return unicode"🛰️";
        if (value == 52) return unicode"🚦";
        if (value == 53) return unicode"🚧";
        if (value == 54) return unicode"🛸";
        if (value == 55) return unicode"🚁";
        if (value == 56) return unicode"⛵";
        if (value == 57) return unicode"⚓";
        if (value == 58) return unicode"🧰";
        if (value == 59) return unicode"🔧";
        if (value == 60) return unicode"🔮";
        if (value == 61) return unicode"🧿";
        if (value == 62) return unicode"🪬";
        return unicode"🗝️";
    }
}
