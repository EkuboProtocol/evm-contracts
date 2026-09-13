// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FreeLPTokenMetadata} from "../../src/libraries/FreeLPTokenMetadata.sol";
import {FreeLPMetadataPrice} from "../../src/libraries/FreeLPMetadataPrice.sol";
import {FreeLPMetadata} from "../../src/libraries/FreeLPMetadata.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract MetadataReturnBomb {
    fallback() external {
        assembly { return(0, 65536) }
    }
}

contract MetadataGasBurner {
    fallback() external {
        assembly { for {} 1 {} {} }
    }
}

contract FreeLPTokenMetadataTest is Test {
    address private constant TOKEN = address(0x1234);
    bytes4 private constant SYMBOL = 0x95d89b41;
    bytes4 private constant NAME = 0x06fdde03;
    bytes4 private constant DECIMALS = 0x313ce567;

    function _set(string memory symbol, string memory name, uint256 decimals) private {
        vm.mockCall(TOKEN, abi.encodeWithSelector(SYMBOL), abi.encode(symbol));
        vm.mockCall(TOKEN, abi.encodeWithSelector(NAME), abi.encode(name));
        vm.mockCall(TOKEN, abi.encodeWithSelector(DECIMALS), abi.encode(decimals));
    }

    function test_standardAndBytes32Metadata() public {
        _set("USDC", "USD Coin", 6);
        FreeLPTokenMetadata.Data memory m = FreeLPTokenMetadata.read(TOKEN);
        assertEq(m.symbol, "USDC");
        assertEq(m.name, "USD Coin");
        assertEq(m.decimals, 6);
        assertTrue(m.hasDecimals);
        vm.mockCall(TOKEN, abi.encodeWithSelector(SYMBOL), abi.encode(bytes32("MKR")));
        vm.mockCall(TOKEN, abi.encodeWithSelector(NAME), abi.encode(bytes32("Maker")));
        m = FreeLPTokenMetadata.read(TOKEN);
        assertEq(m.symbol, "MKR");
        assertEq(m.name, "Maker");
    }

    function test_getterFailuresAreIndependent() public {
        _set("USDC", "USD Coin", 6);
        vm.mockCallRevert(TOKEN, abi.encodeWithSelector(SYMBOL), "unavailable");
        FreeLPTokenMetadata.Data memory m = FreeLPTokenMetadata.read(TOKEN);
        assertEq(m.name, "USD Coin");
        assertEq(m.decimals, 6);
        assertTrue(m.hasDecimals);
        assertTrue(LibString.startsWith(m.symbol, "0x"));
    }

    function test_decimalsZeroAnd255AreKnownBut256AndMalformedAreUnknown() public {
        _set("T", "Token", 0);
        assertTrue(FreeLPTokenMetadata.read(TOKEN).hasDecimals);
        _set("T", "Token", 255);
        assertEq(FreeLPTokenMetadata.read(TOKEN).decimals, 255);
        _set("T", "Token", 256);
        assertFalse(FreeLPTokenMetadata.read(TOKEN).hasDecimals);
        vm.mockCall(TOKEN, abi.encodeWithSelector(DECIMALS), hex"06");
        assertFalse(FreeLPTokenMetadata.read(TOKEN).hasDecimals);
    }

    function test_malformedDynamicReturnDoesNotRevert() public {
        _set("T", "Token", 18);
        vm.mockCall(TOKEN, abi.encodeWithSelector(SYMBOL), abi.encode(uint256(32), type(uint256).max));
        assertTrue(LibString.startsWith(FreeLPTokenMetadata.read(TOKEN).symbol, "0x"));
        vm.mockCall(TOKEN, abi.encodeWithSelector(SYMBOL), abi.encode(uint256(64), uint256(1), bytes32("T")));
        assertTrue(LibString.startsWith(FreeLPTokenMetadata.read(TOKEN).symbol, "0x"));
    }

    function test_returnAndGasBombsRemainBounded() public {
        address bomb = address(new MetadataReturnBomb());
        address burner = address(new MetadataGasBurner());
        uint256 gasBefore = gasleft();
        assertFalse(FreeLPTokenMetadata.read(bomb).hasDecimals);
        assertFalse(FreeLPTokenMetadata.read(burner).hasDecimals);
        assertLt(gasBefore - gasleft(), 200000);
    }

    function test_validUnicodeIsPreservedAndInvalidSequencesAreReplaced() public {
        _set(unicode"币🙂", unicode"美元稳定币", 6);
        assertEq(FreeLPTokenMetadata.read(TOKEN).symbol, unicode"币🙂");
        bytes[4] memory invalid;
        invalid[0] = hex"eda080";
        invalid[1] = hex"e08080";
        invalid[2] = hex"f4908080";
        invalid[3] = hex"0041";
        string[4] memory cleaned = ["???", "???", "????", "?A"];
        for (uint256 i; i < invalid.length; ++i) {
            vm.mockCall(TOKEN, abi.encodeWithSelector(SYMBOL), abi.encode(string(invalid[i])));
            assertEq(FreeLPTokenMetadata.read(TOKEN).symbol, cleaned[i]);
        }
    }

    function test_longUnicodeIsTruncatedOnlyAtCodePointBoundaries() public {
        string memory name;
        for (uint256 i; i < 50; ++i) {
            name = string.concat(name, unicode"币");
        }
        _set(name, name, 18);
        FreeLPTokenMetadata.Data memory m = FreeLPTokenMetadata.read(TOKEN);
        assertEq(bytes(m.symbol).length, 30);
        assertEq(bytes(m.name).length, 96);
        assertEq(LibString.runeCount(FreeLPTokenMetadata.shorten(m.symbol, 8)), 8);
        assertTrue(LibString.endsWith(FreeLPTokenMetadata.shorten(m.symbol, 8), unicode"…"));
    }

    function test_xmlAndJsonUseSeparateEscaping() public {
        _set('<&"\'>', 'Coin "name" </text><script>bad</script>', 6);
        PoolKey memory key = PoolKey(TOKEN, address(0x2345), createConcentratedPoolConfig(0, 10, address(0)));
        string memory uri = FreeLPMetadata.tokenURI(1, address(0x123), key, -1000, 1000);
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertEq(vm.parseJsonString(json, ".properties.token0_symbol"), '<&"\'>');
        string memory svg = string(Base64.decode(LibString.slice(vm.parseJsonString(json, ".image"), 26)));
        assertFalse(LibString.contains(svg, "<script>"));
        assertTrue(LibString.contains(svg, "&lt;"));
        assertTrue(LibString.contains(svg, "&amp;"));
    }

    function test_nativeNamesAndUnknownChainDoNotInventDecimals() public {
        vm.chainId(56);
        assertEq(FreeLPTokenMetadata.read(address(0)).symbol, "BNB");
        vm.chainId(137);
        assertEq(FreeLPTokenMetadata.read(address(0)).symbol, "POL");
        vm.chainId(8453);
        assertEq(FreeLPTokenMetadata.read(address(0)).symbol, "ETH");
        vm.chainId(987654321);
        FreeLPTokenMetadata.Data memory m = FreeLPTokenMetadata.read(address(0));
        assertEq(m.symbol, "NATIVE");
        assertFalse(m.hasDecimals);
    }

    function test_displayPricesUseDecimalsAndKeepScientificFraction() public pure {
        assertEq(FreeLPMetadataPrice.format(0, 18, 18), "1");
        assertEq(FreeLPMetadataPrice.format(-20000000, 18, 6), "2061.17");
        assertEq(FreeLPMetadataPrice.format(-19800000, 18, 6), "2517.52");
        assertEq(FreeLPMetadataPrice.format(1000000, 6, 0), "2.71828e6");
        assertEq(FreeLPMetadataPrice.format(0, 0, 6), "1e-6");
        assertEq(FreeLPMetadataPrice.format(0, 0, 3), "0.001");
    }

    function test_extremeTickAndDecimalPricesRemainRepresentable() public pure {
        assertTrue(LibString.contains(FreeLPMetadataPrice.format(MIN_TICK, 0, 255), "e-"));
        assertTrue(LibString.contains(FreeLPMetadataPrice.format(MAX_TICK, 255, 0), "e"));
        assertTrue(bytes(FreeLPMetadataPrice.format(MAX_TICK, 255, 0)).length < 16);
    }
}
