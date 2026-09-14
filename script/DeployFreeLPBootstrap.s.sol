// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {Core} from "../src/Core.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPMetadataRenderer} from "../src/FreeLPMetadataRenderer.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";
import {PoolConfig} from "../src/types/poolConfig.sol";
import {PoolKey} from "../src/types/poolKey.sol";

/// @notice Deploys or reuses the FreeLP stack and seeds the shared PoolKeyIndex with pools that hold liquidity.
/// @dev Pool keys are fetched from the production API through `vm.ffi` + curl, so `--ffi` is required.
///      Nothing pool-related is stored in the repository. Without `--broadcast` this is a dry run.
contract DeployFreeLPBootstrap is Script {
    using CoreLib for ICore;

    bytes32 public constant SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
    address public constant CORE = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    address public constant POOL_KEY_INDEX = 0x827A68AC37AA3715c865F2E0704a63118496986f;
    address public constant METADATA_RENDERER = 0x3E3142aA2143bC05BA92986a9D4867C1409FB8E2;
    address public constant FREE_LP = 0x0dB596aF023b61c681c91c39E540829bf81bEcD5;
    address public constant DATA_FETCHER = 0x304bDc1869F392740aE879164428ae6A51B71114;

    string public constant API = "https://prod-api.ekubo.org";
    uint256 public constant PAGE_SIZE = 200;

    struct Counts {
        uint256 registered;
        uint256 alreadyRegistered;
        uint256 skippedUninitialized;
    }

    function run() public {
        PoolKey[] memory keys = fetchPoolKeys(block.chainid);
        vm.startBroadcast();
        (ICore core, PoolKeyIndex index) = deployContracts();
        bootstrap(core, index, keys);
        vm.stopBroadcast();
    }

    /// @notice Deploys or reuses Core, PoolKeyIndex, FreeLPMetadataRenderer, FreeLP, and FreeLPDataFetcher.
    function deployContracts() public returns (ICore core, PoolKeyIndex index) {
        (address coreAddress,) = deployIfNeeded(type(Core).creationCode, SALT, CORE, "Core");
        core = ICore(payable(coreAddress));
        (address indexAddress,) = deployIfNeeded(
            abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core)), SALT, POOL_KEY_INDEX, "PoolKeyIndex"
        );
        (address renderer,) =
            deployIfNeeded(type(FreeLPMetadataRenderer).creationCode, SALT, METADATA_RENDERER, "FreeLPMetadataRenderer");
        deployIfNeeded(
            abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, indexAddress, renderer)),
            SALT,
            FREE_LP,
            "FreeLP"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)),
            SALT,
            DATA_FETCHER,
            "FreeLPDataFetcher"
        );
        index = PoolKeyIndex(indexAddress);
    }

    /// @notice Registers every initialized, not-yet-registered key in one `registerMultiple` call. Safe to rerun.
    function bootstrap(ICore core, PoolKeyIndex index, PoolKey[] memory keys) public returns (Counts memory counts) {
        PoolKey[] memory pending;
        (pending, counts) = selectPending(core, index, keys);
        if (pending.length != 0) index.registerMultiple(pending);
        counts.registered = pending.length;
        console2.log("Registered pool keys:", counts.registered);
        console2.log("Already registered pool keys:", counts.alreadyRegistered);
        console2.log("Skipped uninitialized pool keys:", counts.skippedUninitialized);
    }

    /// @notice Pages through the API for the chain's canonical Core and keeps pools with non-zero liquidity.
    function fetchPoolKeys(uint256 chainId) public returns (PoolKey[] memory keys) {
        string memory base = string.concat(
            API, "/poolKeys/", vm.toString(chainId), "/", vm.toString(CORE), "?limit=", vm.toString(PAGE_SIZE)
        );
        string memory cursor = "";
        bool hasMore = true;
        while (hasMore) {
            string memory url = bytes(cursor).length == 0 ? base : string.concat(base, "&after=", cursor);
            string memory page = fetch(url);
            keys = concat(keys, parsePoolKeys(page));
            hasMore = vm.parseJsonBool(page, ".has_more");
            if (hasMore) cursor = vm.parseJsonString(page, ".next_cursor");
        }
        console2.log("Fetched pool keys with liquidity:", keys.length);
    }

    /// @notice Extracts pool keys with non-zero liquidity from one API page.
    function parsePoolKeys(string memory json) public view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](PAGE_SIZE);
        uint256 count;
        for (uint256 i = 0; vm.keyExistsJson(json, pool(i, "")); i++) {
            if (!hasLiquidity(json, i)) continue;
            keys[count++] = PoolKey({
                token0: address(uint160(vm.parseUint(vm.parseJsonString(json, pool(i, ".pool_key.token0"))))),
                token1: address(uint160(vm.parseUint(vm.parseJsonString(json, pool(i, ".pool_key.token1"))))),
                config: PoolConfig.wrap(bytes32(vm.parseUint(vm.parseJsonString(json, pool(i, ".pool_key.config")))))
            });
        }
        assembly ("memory-safe") {
            mstore(keys, count)
        }
    }

    function hasLiquidity(string memory json, uint256 i) internal view returns (bool) {
        string memory key = pool(i, ".state.liquidity");
        if (!vm.keyExistsJson(json, key)) return false;
        return keccak256(bytes(vm.parseJsonString(json, key))) != keccak256("0");
    }

    function pool(uint256 i, string memory suffix) internal pure returns (string memory) {
        return string.concat(".pools[", vm.toString(i), "]", suffix);
    }

    function fetch(string memory url) internal returns (string memory) {
        string[] memory command = new string[](6);
        command[0] = "curl";
        command[1] = "-sS";
        command[2] = "--fail";
        command[3] = "--max-time";
        command[4] = "60";
        command[5] = url;
        return string(vm.ffi(command));
    }

    function selectPending(ICore core, PoolKeyIndex index, PoolKey[] memory keys)
        internal
        view
        returns (PoolKey[] memory pending, Counts memory counts)
    {
        pending = new PoolKey[](keys.length);
        uint256 count;
        for (uint256 i = 0; i < keys.length; i++) {
            if (!core.poolState(keys[i].toPoolId()).isInitialized()) {
                counts.skippedUninitialized++;
            } else if (index.isRegistered(keys[i].toPoolId())) {
                counts.alreadyRegistered++;
            } else {
                pending[count++] = keys[i];
            }
        }
        assembly ("memory-safe") {
            mstore(pending, count)
        }
    }

    function concat(PoolKey[] memory a, PoolKey[] memory b) internal pure returns (PoolKey[] memory result) {
        result = new PoolKey[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }
}
