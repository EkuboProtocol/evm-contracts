// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Test} from "forge-std/Test.sol";

import {VeTokenMetadata} from "../../src/libraries/VeTokenMetadata.sol";

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

    function _standardParams() internal pure returns (VeTokenMetadata.Params memory) {
        return VeTokenMetadata.Params({
            id: 1,
            amount: 15e17,
            unlockTime: 126_144_000,
            veSymbol: "veTT",
            stakeTokenName: "TestToken",
            stakeTokenSymbol: "TT",
            stakeTokenDecimals: 18,
            stakeToken: 0xa0Cb889707d426A7A386870A03bc70d1b0697598
        });
    }

    function _escapedParams() internal pure returns (VeTokenMetadata.Params memory) {
        return VeTokenMetadata.Params({
            id: 42,
            amount: 123_456_789,
            unlockTime: 1_893_456_000,
            veSymbol: "ve\"E&K<",
            stakeTokenName: "Ekubo \"Stake\" & Vote",
            stakeTokenSymbol: "E<K&\"",
            stakeTokenDecimals: 6,
            stakeToken: 0x1111111111111111111111111111111111111111
        });
    }

    function _zeroDecimalParams() internal pure returns (VeTokenMetadata.Params memory) {
        return VeTokenMetadata.Params({
            id: 999,
            amount: 123_456_789,
            unlockTime: 0,
            veSymbol: "veWHOLE",
            stakeTokenName: "Whole Token",
            stakeTokenSymbol: "WHOLE",
            stakeTokenDecimals: 0,
            stakeToken: address(0)
        });
    }

    function _tinyAmountParams() internal pure returns (VeTokenMetadata.Params memory) {
        return VeTokenMetadata.Params({
            id: 7,
            amount: 1,
            unlockTime: 4_102_444_799,
            veSymbol: "veDUST",
            stakeTokenName: "Dust Token",
            stakeTokenSymbol: "DUST",
            stakeTokenDecimals: 18,
            stakeToken: 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF
        });
    }

    function _metadataCase(string memory label, VeTokenMetadata.Params memory params)
        internal
        pure
        returns (string memory)
    {
        return string.concat("== ", label, " tokenURI json ==\n", VeTokenMetadata.tokenJson(params));
    }

    function _metadataSnapshot() internal pure returns (string memory) {
        return string.concat(
            _metadataCase("standard", _standardParams()),
            "\n\n",
            _metadataCase("escaped", _escapedParams()),
            "\n\n",
            _metadataCase("zero-decimals", _zeroDecimalParams()),
            "\n\n",
            _metadataCase("tiny-amount", _tinyAmountParams())
        );
    }

    function _formatSnapshot() internal pure returns (string memory) {
        return string.concat(
            "amount 0 decimals 18: ",
            VeTokenMetadata.formatTokenAmount(0, 18),
            "\namount 1 decimals 18: ",
            VeTokenMetadata.formatTokenAmount(1, 18),
            "\namount 10 decimals 2: ",
            VeTokenMetadata.formatTokenAmount(10, 2),
            "\namount 100 decimals 2: ",
            VeTokenMetadata.formatTokenAmount(100, 2),
            "\namount 123456789 decimals 6: ",
            VeTokenMetadata.formatTokenAmount(123_456_789, 6),
            "\namount 123456789 decimals 0: ",
            VeTokenMetadata.formatTokenAmount(123_456_789, 0),
            "\ndate 0: ",
            VeTokenMetadata.formatDate(0),
            "\ndate 126144000: ",
            VeTokenMetadata.formatDate(126_144_000),
            "\ndate 1893456000: ",
            VeTokenMetadata.formatDate(1_893_456_000),
            "\ndate 4102444799: ",
            VeTokenMetadata.formatDate(4_102_444_799)
        );
    }

    function test_tokenURIAndSvg_snapshotsDifferentInputs() public view {
        _assertSnapshotEq(bytes(_metadataSnapshot()), "snapshots/VeTokenMetadata.txt");
        _assertSnapshotEq(bytes(VeTokenMetadata.tokenSvg(_standardParams())), "snapshots/VeTokenMetadataStandard.svg");
        _assertSnapshotEq(bytes(VeTokenMetadata.tokenSvg(_escapedParams())), "snapshots/VeTokenMetadataEscaped.svg");
        _assertSnapshotEq(
            bytes(VeTokenMetadata.tokenSvg(_zeroDecimalParams())), "snapshots/VeTokenMetadataZeroDecimals.svg"
        );
        _assertSnapshotEq(
            bytes(VeTokenMetadata.tokenSvg(_tinyAmountParams())), "snapshots/VeTokenMetadataTinyAmount.svg"
        );
    }

    function test_tokenURI_encodesTokenJson() public pure {
        VeTokenMetadata.Params memory params = _escapedParams();
        string memory prefix = "data:application/json;base64,";
        string memory uri = VeTokenMetadata.tokenURI(params);
        assertTrue(LibString.startsWith(uri, prefix));
        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        assertEq(json, VeTokenMetadata.tokenJson(params));
    }

    function test_formatting_snapshotsEdgeCases() public view {
        _assertSnapshotEq(bytes(_formatSnapshot()), "snapshots/VeTokenMetadataFormats.txt");
    }
}
