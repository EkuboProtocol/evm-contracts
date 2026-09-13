// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FreeLPMetadata} from "../../src/libraries/FreeLPMetadata.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";

contract FreeLPMetadataTest is Test {
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
        assertEq(string(Base64.decode(LibString.slice(vm.parseJsonString(json, ".image"), 26))), svg);
        assertEq(vm.parseJsonString(json, ".properties.tick_lower"), LibString.toString(int256(lower)));
        assertEq(vm.parseJsonString(json, ".properties.tick_upper"), LibString.toString(int256(upper)));
        _snapshot(json, string.concat("snapshots/FreeLPMetadata", label, ".json"));
    }

    function test_concentratedSnapshot() public {
        vm.chainId(1);
        _case(
            "Concentrated",
            1,
            PoolKey(address(0x1111), address(0x2222), createConcentratedPoolConfig(1 << 60, 10, address(0))),
            -1000,
            1000
        );
    }

    function test_nativeStableswapSnapshot() public {
        vm.chainId(8453);
        PoolKey memory key = PoolKey(address(0), address(0x3333), createStableswapPoolConfig(0, 10, 0, address(0)));
        (int32 lower, int32 upper) = key.config.stableswapActiveLiquidityTickRange();
        _case("NativeStableswap", 42, key, lower, upper);
    }

    function test_extremeBoundsAndIdSnapshot() public {
        vm.chainId(1);
        _case(
            "Extreme",
            type(uint64).max,
            PoolKey(
                address(0x1111),
                address(type(uint160).max),
                createConcentratedPoolConfig(type(uint64).max, 1, address(type(uint160).max))
            ),
            MIN_TICK,
            MAX_TICK
        );
    }
}
