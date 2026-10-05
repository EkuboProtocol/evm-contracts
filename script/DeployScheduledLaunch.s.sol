// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {deployExtension} from "./DeployAll.s.sol";

/// @notice Deploys ScheduledLaunch, which deploys its LockedLaunchLiquidity, on any chain with Ekubo Core and
/// TWAMM. CORE_ADDRESS and TWAMM_ADDRESS are required. SALT is the starting salt for the hook-prefix search
/// and SCHEDULED_LAUNCH_ADDRESS optionally pins the expected address.
/// @dev Dry run by default: transactions are recorded only with BROADCAST=true, and sent only when forge
/// also gets --broadcast.
contract DeployScheduledLaunch is Script {
    using CoreLib for ICore;

    error MissingDeployment(string name, address expected);
    error TwammMismatch(address expected, address actual);
    error TwammNotRegistered(address twamm);

    function run() public virtual returns (ScheduledLaunch extension) {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        address twamm = vm.envAddress("TWAMM_ADDRESS");
        bytes32 salt = vm.envOr("SALT", bytes32(0));
        address expected = vm.envOr("SCHEDULED_LAUNCH_ADDRESS", address(0));
        bool broadcast = vm.envOr("BROADCAST", false);

        if (broadcast) vm.startBroadcast();
        extension = _deploy(core, twamm, salt, expected);
        if (broadcast) vm.stopBroadcast();

        console2.log("chain id", block.chainid);
        console2.log("broadcast", broadcast);
        console2.log("ScheduledLaunch", address(extension));
        console2.log("ScheduledLaunch code hash", vm.toString(address(extension).codehash));
        console2.log("LockedLaunchLiquidity", address(extension.LIQUIDITY()));
        console2.log("LockedLaunchLiquidity code hash", vm.toString(address(extension.LIQUIDITY()).codehash));
    }

    function _deploy(ICore core, address twamm, bytes32 salt, address expected)
        internal
        returns (ScheduledLaunch extension)
    {
        if (address(core).code.length == 0) revert MissingDeployment("Core", address(core));
        if (twamm.code.length == 0) revert MissingDeployment("TWAMM", twamm);
        (address deployed,) = deployExtension(
            abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core, twamm)),
            salt,
            scheduledLaunchCallPoints(),
            expected,
            "ScheduledLaunch"
        );
        extension = ScheduledLaunch(deployed);
        _checkTwamm(core, twamm, extension);
    }

    /// @dev Reads the terminal-pool TWAMM back from the deployed extension. A nonzero address alone proves
    /// nothing: it must be the configured TWAMM and a Core-registered extension.
    function _checkTwamm(ICore core, address twamm, ScheduledLaunch extension) internal view returns (bool) {
        address actual = extension.TWAMM();
        if (actual != twamm) revert TwammMismatch(twamm, actual);
        if (!core.isExtensionRegistered(actual)) revert TwammNotRegistered(actual);
        return true;
    }
}
