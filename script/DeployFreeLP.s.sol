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
            0x898956fc2Aed01D5F81F556FF5dcB10534285718,
            "PoolKeyIndex"
        );
        (address renderer,) = deployIfNeeded(
            type(FreeLPMetadataRenderer).creationCode,
            SALT,
            0xAD70a7A70678C57FBB52a9aFF6a2E0884E226f86,
            "FreeLPMetadataRenderer"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index, renderer)),
            SALT,
            0x7F818932a0963199aFd8778c905972eeFDBF1EE5,
            "FreeLP"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)),
            SALT,
            0xC1eDB9fab9C14C07938b4a0FA848B9F51eaC9FF7,
            "FreeLPDataFetcher"
        );
        vm.stopBroadcast();
    }
}
