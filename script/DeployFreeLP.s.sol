// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {FreeLP} from "../src/FreeLP.sol";
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
        deployIfNeeded(
            abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index)),
            SALT,
            0xE7483a2F17A0F77480BDAc3bdb27CB002088BaA1,
            "FreeLP"
        );
        deployIfNeeded(
            abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)),
            SALT,
            0x53f94Bf2f022F4E31Be9B336C80555020f6009cD,
            "FreeLPDataFetcher"
        );
        vm.stopBroadcast();
    }
}
