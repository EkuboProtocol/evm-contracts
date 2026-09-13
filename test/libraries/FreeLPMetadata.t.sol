// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FreeLPMetadata} from "../../src/libraries/FreeLPMetadata.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";

contract MetadataToken {
    string public symbol;
    string public name;
    uint8 public decimals;

    constructor(string memory symbol_, string memory name_, uint8 decimals_) {
        symbol = symbol_;
        name = name_;
        decimals = decimals_;
    }
}

contract Bytes32MetadataToken {
    function symbol() external pure returns (bytes32) {
        return "B32";
    }

    function name() external pure returns (bytes32) {
        return "Bytes32 token";
    }

    function decimals() external pure returns (uint256) {
        return 0;
    }
}

contract BrokenMetadataToken {
    function symbol() external pure returns (string memory) {
        revert();
    }

    function name() external pure returns (string memory) {
        assembly ("memory-safe") { revert(0, 0) }
    }

    function decimals() external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 256)
            return(0, 32)
        }
    }
}

contract FreeLPMetadataTest is Test {
    function _metadata(address token, string memory symbol, string memory name, uint8 decimals) private {
        vm.mockCall(token, abi.encodeWithSignature("symbol()"), abi.encode(symbol));
        vm.mockCall(token, abi.encodeWithSignature("name()"), abi.encode(name));
        vm.mockCall(token, abi.encodeWithSignature("decimals()"), abi.encode(decimals));
    }

    /// @dev Regenerate explicitly with UPDATE_SNAPSHOTS=true and a snapshots write permission override.
    function _snapshot(string memory actual, string memory path) private {
        if (vm.envOr("UPDATE_SNAPSHOTS", false)) vm.writeFile(path, string.concat(actual, "\n"));
        string memory expected = vm.readFile(path);
        if (LibString.endsWith(expected, "\n")) expected = LibString.slice(expected, 0, bytes(expected).length - 1);
        assertEq(actual, expected, path);
    }

    function _case(string memory label, uint256 id, PoolKey memory key, int32 lower, int32 upper) private {
        string memory svg = FreeLPMetadata.tokenSvg(id, key, lower, upper);
        _snapshot(svg, string.concat("snapshots/FreeLPMetadata", label, ".svg"));
        string memory uri = FreeLPMetadata.tokenURI(id, address(0x1234), key, lower, upper);
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Liquidity Position #", LibString.toString(id)));
        assertEq(string(Base64.decode(LibString.slice(vm.parseJsonString(json, ".image"), 26))), svg);
        assertEq(vm.parseJsonString(json, ".properties.tick_lower"), LibString.toString(int256(lower)));
        assertEq(vm.parseJsonString(json, ".properties.tick_upper"), LibString.toString(int256(upper)));
        assertEq(vm.parseJsonString(json, ".properties.token0"), LibString.toHexString(key.token0));
        assertEq(vm.parseJsonString(json, ".properties.token1"), LibString.toHexString(key.token1));
        assertFalse(LibString.contains(svg, LibString.toHexString(key.token0)));
        assertFalse(LibString.contains(svg, LibString.toHexString(key.token1)));
        assertFalse(LibString.contains(svg, "Raw ticks"));
        _snapshot(json, string.concat("snapshots/FreeLPMetadata", label, ".json"));
    }

    function test_concentratedSnapshot() public {
        vm.chainId(1);
        _metadata(address(0x1111), "WETH", "Wrapped Ether", 18);
        _metadata(address(0x2222), "USDC", "USD Coin", 6);
        _case(
            "Concentrated",
            1,
            PoolKey(address(0x1111), address(0x2222), createConcentratedPoolConfig(1 << 60, 10, address(0))),
            -20000000,
            -19800000
        );
    }

    function test_nativeStableswapSnapshot() public {
        vm.chainId(8453);
        _metadata(address(0x3333), "WETH", "Wrapped Ether", 18);
        PoolKey memory key = PoolKey(address(0), address(0x3333), createStableswapPoolConfig(0, 10, 0, address(0)));
        (int32 lower, int32 upper) = key.config.stableswapActiveLiquidityTickRange();
        _case("NativeStableswap", 42, key, lower, upper);
    }

    function test_extremeBoundsAndIdSnapshot() public {
        vm.chainId(1);
        _metadata(address(0x1111), "ZERO", "Zero-decimal token", 0);
        _metadata(address(type(uint160).max), "MAX", "255-decimal token", 255);
        _case(
            "Extreme",
            type(uint256).max,
            PoolKey(
                address(0x1111),
                address(type(uint160).max),
                createConcentratedPoolConfig(type(uint64).max, 1, address(type(uint160).max))
            ),
            MIN_TICK,
            MAX_TICK
        );
    }

    function test_metadataAndPriceFormatting() public {
        MetadataToken weth = new MetadataToken("WETH", "Wrapped Ether", 18);
        MetadataToken usdc = new MetadataToken("USDC", "USD Coin", 6);
        PoolKey memory key =
            PoolKey(address(weth), address(usdc), createConcentratedPoolConfig(1 << 60, 10, address(0)));
        string memory svg = FreeLPMetadata.tokenSvg(7, key, -20000000, -19800000);
        assertTrue(LibString.contains(svg, "USDC / WETH"));
        assertTrue(LibString.contains(svg, "Wrapped Ether"));
        assertTrue(LibString.contains(svg, "USD Coin"));
        assertTrue(LibString.contains(svg, "6 / 18 decimals"));
        assertTrue(LibString.contains(svg, "USDC per WETH"));
        assertTrue(LibString.contains(svg, "2061.17"));
        assertTrue(LibString.contains(svg, "2517.52"));
        string memory json =
            string(Base64.decode(LibString.slice(FreeLPMetadata.tokenURI(7, address(0x1234), key, 0, 1), 29)));
        assertEq(vm.parseJsonString(json, ".properties.token0_symbol"), "WETH");
        assertEq(vm.parseJsonUint(json, ".properties.token1_decimals"), 6);
    }

    function test_metadataBytes32AndFailuresAreSafe() public {
        Bytes32MetadataToken bytes32Token = new Bytes32MetadataToken();
        BrokenMetadataToken broken = new BrokenMetadataToken();
        PoolKey memory key =
            PoolKey(address(bytes32Token), address(broken), createConcentratedPoolConfig(1 << 60, 10, address(0)));
        string memory svg = FreeLPMetadata.tokenSvg(8, key, -1, 1);
        assertTrue(LibString.contains(svg, " / B32"));
        assertTrue(LibString.contains(svg, "Bytes32 token"));
        assertTrue(LibString.contains(svg, "Unknown token"));
        assertTrue(LibString.contains(svg, "Unknown / 0 decimals"));
        assertTrue(LibString.contains(svg, "Token decimals unavailable"));
        assertFalse(LibString.contains(svg, "Tick range"));
        assertTrue(LibString.contains(svg, unicode">—</text>"));
    }

    function test_longNamesSnapshot() public {
        vm.chainId(1);
        _metadata(
            address(0x1111),
            unicode"非常长的代币符号",
            unicode"非常长的代币名称在图中仍然保持可读性并被正确截断",
            18
        );
        _metadata(address(0x2222), "LONG&SYMBOL", 'A long token name with <markup> and "quotes"', 6);
        _case(
            "LongNames",
            123,
            PoolKey(address(0x1111), address(0x2222), createConcentratedPoolConfig(0, 10, address(0))),
            -20000000,
            -19800000
        );
    }
}
