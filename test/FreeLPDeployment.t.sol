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
        assertEq(renderer, 0xAD70a7A70678C57FBB52a9aFF6a2E0884E226f86);
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index, renderer)))
            ),
            0x7F818932a0963199aFd8778c905972eeFDBF1EE5
        );
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)))
            ),
            0xC1eDB9fab9C14C07938b4a0FA848B9F51eaC9FF7
        );
    }
}
