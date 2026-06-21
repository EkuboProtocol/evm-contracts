// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {VeToken} from "../src/VeToken.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployVe33
/// @notice Deploys the Ve33 extension, VeToken ERC721 wrapper, and Ve33Periphery.
contract DeployVe33 is Script {
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address expectedVe33 = vm.envOr("VE33_ADDRESS", address(0));
        address expectedVeToken = vm.envOr("VE_TOKEN_ADDRESS", address(0));
        address expectedPeriphery = vm.envOr("VE33_PERIPHERY_ADDRESS", address(0));

        vm.startBroadcast();

        (address ve33Address, bytes32 ve33Salt) = deployExtension(
            abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stakeToken)),
            salt,
            ve33CallPoints(),
            expectedVe33,
            "Ve33"
        );
        console2.log("Ve33 salt:");
        console2.logBytes32(ve33Salt);

        Ve33 ve33 = Ve33(payable(ve33Address));

        deployIfNeeded(
            abi.encodePacked(type(VeToken).creationCode, abi.encode(core, ve33)), salt, expectedVeToken, "VeToken"
        );
        deployIfNeeded(
            abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
            salt,
            expectedPeriphery,
            "Ve33Periphery"
        );

        vm.stopBroadcast();
    }
}
