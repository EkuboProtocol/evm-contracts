// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {getCreate2Address} from "../script/DeployAll.s.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPMetadataRenderer} from "../src/FreeLPMetadataRenderer.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";

contract FreeLPDeploymentTest is Test {
    function test_deploymentAddresses() public pure {
        bytes32 salt = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
        address core = 0x00000000000014aA86C5d3c41765bb24e11bd701;
        address index =
            getCreate2Address(salt, keccak256(abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core))));
        assertEq(index, 0x827A68AC37AA3715c865F2E0704a63118496986f);
        address renderer = getCreate2Address(salt, keccak256(type(FreeLPMetadataRenderer).creationCode));
        assertEq(renderer, 0x3E3142aA2143bC05BA92986a9D4867C1409FB8E2);
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index, renderer)))
            ),
            0x0dB596aF023b61c681c91c39E540829bf81bEcD5
        );
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)))
            ),
            0x304bDc1869F392740aE879164428ae6A51B71114
        );
    }
}
