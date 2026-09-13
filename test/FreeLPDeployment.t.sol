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
        assertEq(index, 0x898956fc2Aed01D5F81F556FF5dcB10534285718);
        address renderer = getCreate2Address(salt, keccak256(type(FreeLPMetadataRenderer).creationCode));
        assertEq(renderer, 0x3E3142aA2143bC05BA92986a9D4867C1409FB8E2);
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index, renderer)))
            ),
            0xa03d8d3354453aB0056E190Ab0f0020f7CC8d76C
        );
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)))
            ),
            0xE8E86fD702B1e0A18593d853Df9487D436ce17BC
        );
    }
}
