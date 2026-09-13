// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPMetadataRenderer} from "../src/FreeLPMetadataRenderer.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";

/// @notice Deploys the RPC-discoverable FreeLP stack against the canonical Core.
contract DeployFreeLP is Script {
    bytes32 constant SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        ICore core = ICore(payable(0x00000000000014aA86C5d3c41765bb24e11bd701));
        vm.startBroadcast();
        (address index,) = deployIfNeeded(
            abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core)),
            SALT,
            0x827A68AC37AA3715c865F2E0704a63118496986f,
            "PoolKeyIndex"
        );
        (address renderer,) = deployIfNeeded(
            type(FreeLPMetadataRenderer).creationCode,
            SALT,
            0x3E3142aA2143bC05BA92986a9D4867C1409FB8E2,
            "FreeLPMetadataRenderer"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index, renderer)),
            SALT,
            0x0b1605F6ab7CC5A51846cbaCc2A73730C7770c4C,
            "FreeLP"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)),
            SALT,
            0xf4653c16A87828D3901E376eB3578fA50c5bbdD5,
            "FreeLPDataFetcher"
        );
        vm.stopBroadcast();
    }
}
