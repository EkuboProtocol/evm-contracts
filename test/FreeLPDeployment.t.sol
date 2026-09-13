// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {getCreate2Address} from "../script/DeployAll.s.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";

contract FreeLPDeploymentTest is Test {
    function test_deploymentAddresses() public pure {
        bytes32 salt = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
        address core = 0x00000000000014aA86C5d3c41765bb24e11bd701;
        address index =
            getCreate2Address(salt, keccak256(abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core))));
        assertEq(index, 0x898956fc2Aed01D5F81F556FF5dcB10534285718);
        assertEq(
            getCreate2Address(salt, keccak256(abi.encodePacked(type(FreeLP).creationCode, abi.encode(core, index)))),
            0xE7483a2F17A0F77480BDAc3bdb27CB002088BaA1
        );
        assertEq(
            getCreate2Address(
                salt, keccak256(abi.encodePacked(type(FreeLPDataFetcher).creationCode, abi.encode(core)))
            ),
            0x53f94Bf2f022F4E31Be9B336C80555020f6009cD
        );
    }
}
