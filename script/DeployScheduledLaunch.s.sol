// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {deployExtension} from "./DeployAll.s.sol";

/// @notice Deploys the launch extension with its required hook address prefix.
contract DeployScheduledLaunch is Script {
    function run() public returns (ScheduledLaunch extension) {
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", address(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        bytes32 startingSalt = vm.envOr("SALT", bytes32(0));
        address expected = vm.envOr("SCHEDULED_LAUNCH_ADDRESS", address(0));
        vm.startBroadcast();
        (address deployed,) = deployExtension(
            abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core)),
            startingSalt,
            scheduledLaunchCallPoints(),
            expected,
            "ScheduledLaunch"
        );
        vm.stopBroadcast();
        extension = ScheduledLaunch(deployed);
    }
}
