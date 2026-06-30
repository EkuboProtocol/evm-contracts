// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {SignedExclusiveSwap, signedExclusiveSwapCallPoints} from "../src/extensions/SignedExclusiveSwap.sol";
import {deployExtension} from "./DeployAll.s.sol";

/// @title DeploySignedExclusiveSwap
/// @notice Deploys SignedExclusiveSwap with an owner and core address suitable for public use.
contract DeploySignedExclusiveSwap is Script {
    function run() public {
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", address(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        bytes32 startingSalt = vm.envOr("SALT", bytes32(0));
        address expectedAddress = vm.envOr("EXPECTED_ADDRESS", address(0));

        bytes memory initCode = abi.encodePacked(type(SignedExclusiveSwap).creationCode, abi.encode(core, owner));
        vm.startBroadcast();
        deployExtension(initCode, startingSalt, signedExclusiveSwapCallPoints(), expectedAddress, "SignedExclusiveSwap");
        vm.stopBroadcast();
    }
}
