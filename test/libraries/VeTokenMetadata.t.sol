// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Test} from "forge-std/Test.sol";

import {VeTokenMetadata} from "../../src/VeTokenMetadata.sol";

contract VeTokenMetadataTest is Test {
    function _readSnapshotBytes(string memory path) internal view returns (bytes memory) {
        bytes memory data = bytes(vm.readFile(path));
        if (data.length != 0 && data[data.length - 1] == 0x0a) {
            bytes memory trimmed = new bytes(data.length - 1);
            for (uint256 i; i < trimmed.length; i++) {
                trimmed[i] = data[i];
            }
            data = trimmed;
        }
        return data;
    }

    function _assertSnapshotEq(bytes memory actual, string memory path) internal view {
        bytes memory expected = _readSnapshotBytes(path);
        assertEq(actual.length, expected.length, string.concat(path, " length"));
        for (uint256 i = 0; i < actual.length; i++) {
            assertEq(uint8(actual[i]), uint8(expected[i]), string.concat(path, " byte ", vm.toString(i)));
        }
    }

    function _standardMetadata() internal returns (VeTokenMetadata) {
        return new VeTokenMetadata("TestToken", "TT", 18, 0xa0Cb889707d426A7A386870A03bc70d1b0697598);
    }

    function _escapedMetadata() internal returns (VeTokenMetadata) {
        return new VeTokenMetadata("Ekubo \"Stake\" & Vote", "E<K&\"", 6, 0x1111111111111111111111111111111111111111);
    }

    function _zeroDecimalMetadata() internal returns (VeTokenMetadata) {
        return new VeTokenMetadata("Whole Token", "WHOLE", 0, address(0));
    }

    function _tinyAmountMetadata() internal returns (VeTokenMetadata) {
        return new VeTokenMetadata("Dust Token", "DUST", 18, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }

    function _metadataCase(
        string memory label,
        VeTokenMetadata metadata,
        uint256 id,
        uint128 amount,
        uint64 unlockTime,
        string memory veSymbol
    ) internal view returns (string memory) {
        return string.concat("== ", label, " tokenURI json ==\n", metadata.tokenJson(id, amount, unlockTime, veSymbol));
    }

    function _metadataSnapshot() internal returns (string memory) {
        return string.concat(
            _metadataCase("standard", _standardMetadata(), 1, 15e17, 126_144_000, "veTT"),
            "\n\n",
            _metadataCase("escaped", _escapedMetadata(), 42, 123_456_789, 1_893_456_000, "ve\"E&K<"),
            "\n\n",
            _metadataCase("zero-decimals", _zeroDecimalMetadata(), 999, 123_456_789, 0, "veWHOLE"),
            "\n\n",
            _metadataCase("tiny-amount", _tinyAmountMetadata(), 7, 1, 4_102_444_799, "veDUST")
        );
    }

    function _formatSnapshot(VeTokenMetadata metadata) internal view returns (string memory) {
        return string.concat(
            "amount 0 decimals 18: ",
            metadata.formatTokenAmount(0, 18),
            "\namount 1 decimals 18: ",
            metadata.formatTokenAmount(1, 18),
            "\namount 10 decimals 2: ",
            metadata.formatTokenAmount(10, 2),
            "\namount 100 decimals 2: ",
            metadata.formatTokenAmount(100, 2),
            "\namount 123456789 decimals 6: ",
            metadata.formatTokenAmount(123_456_789, 6),
            "\namount 123456789 decimals 0: ",
            metadata.formatTokenAmount(123_456_789, 0),
            "\ndate 0: ",
            metadata.formatDate(0),
            "\ndate 126144000: ",
            metadata.formatDate(126_144_000),
            "\ndate 1893456000: ",
            metadata.formatDate(1_893_456_000),
            "\ndate 4102444799: ",
            metadata.formatDate(4_102_444_799)
        );
    }

    function test_tokenURIAndSvg_snapshotsDifferentInputs() public {
        _assertSnapshotEq(bytes(_metadataSnapshot()), "snapshots/VeTokenMetadata.txt");
        _assertSnapshotEq(
            bytes(_standardMetadata().tokenSvg(1, 15e17, 126_144_000, "veTT")), "snapshots/VeTokenMetadataStandard.svg"
        );
        _assertSnapshotEq(
            bytes(_escapedMetadata().tokenSvg(42, 123_456_789, 1_893_456_000, "ve\"E&K<")),
            "snapshots/VeTokenMetadataEscaped.svg"
        );
        _assertSnapshotEq(
            bytes(_zeroDecimalMetadata().tokenSvg(999, 123_456_789, 0, "veWHOLE")),
            "snapshots/VeTokenMetadataZeroDecimals.svg"
        );
        _assertSnapshotEq(
            bytes(_tinyAmountMetadata().tokenSvg(7, 1, 4_102_444_799, "veDUST")),
            "snapshots/VeTokenMetadataTinyAmount.svg"
        );
    }

    function test_tokenURI_encodesTokenJson() public {
        VeTokenMetadata metadata = _escapedMetadata();
        string memory prefix = "data:application/json;base64,";
        string memory uri = metadata.tokenURI(42, 123_456_789, 1_893_456_000, "ve\"E&K<");
        assertTrue(LibString.startsWith(uri, prefix));
        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        assertEq(json, metadata.tokenJson(42, 123_456_789, 1_893_456_000, "ve\"E&K<"));
    }

    function test_constructor_revertsIfPackedStringTooLong() public {
        vm.expectRevert(VeTokenMetadata.PackedStringTooLong.selector);
        new VeTokenMetadata("12345678901234567890123456789012", "TT", 18, address(0));
    }

    function test_formatting_snapshotsEdgeCases() public {
        _assertSnapshotEq(bytes(_formatSnapshot(_standardMetadata())), "snapshots/VeTokenMetadataFormats.txt");
    }
}
