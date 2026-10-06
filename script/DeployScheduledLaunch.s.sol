// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @notice Deploys ScheduledLaunch, which deploys its LockedLaunchLiquidity, and the LaunchRouter periphery on
/// any chain with Ekubo Core and TWAMM: three contracts. CORE_ADDRESS and TWAMM_ADDRESS are required. SALT is
/// the starting salt for the hook-prefix search and the router's CREATE2 salt; SCHEDULED_LAUNCH_ADDRESS and
/// LAUNCH_ROUTER_ADDRESS optionally pin the expected addresses.
/// @dev Dry run by default: transactions are recorded only with BROADCAST=true, and sent only when forge
/// also gets --broadcast.
contract DeployScheduledLaunch is Script {
    using CoreLib for ICore;

    error MissingDeployment(string name, address expected);
    error TwammMismatch(address expected, address actual);
    error TwammNotRegistered(address twamm);
    error RouterMismatch(address router);

    function run() public virtual returns (ScheduledLaunch extension) {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        address twamm = vm.envAddress("TWAMM_ADDRESS");
        bytes32 salt = vm.envOr("SALT", bytes32(0));
        address expected = vm.envOr("SCHEDULED_LAUNCH_ADDRESS", address(0));
        address expectedRouter = vm.envOr("LAUNCH_ROUTER_ADDRESS", address(0));
        bool broadcast = vm.envOr("BROADCAST", false);

        if (broadcast) vm.startBroadcast();
        extension = _deploy(core, twamm, salt, expected);
        LaunchRouter launchRouter = _deployRouter(core, extension, salt, expectedRouter);
        if (broadcast) vm.stopBroadcast();

        console2.log("chain id", block.chainid);
        console2.log("broadcast", broadcast);
        console2.log("ScheduledLaunch", address(extension));
        console2.log("ScheduledLaunch code hash", vm.toString(address(extension).codehash));
        console2.log("LockedLaunchLiquidity", address(extension.LIQUIDITY()));
        console2.log("LockedLaunchLiquidity code hash", vm.toString(address(extension.LIQUIDITY()).codehash));
        console2.log("LaunchRouter", address(launchRouter));
        console2.log("LaunchRouter code hash", vm.toString(address(launchRouter).codehash));
    }

    /// @dev Plain CREATE2 through the deterministic deployer; the router needs no address prefix.
    function _deployRouter(ICore core, ScheduledLaunch extension, bytes32 salt, address expected)
        internal
        returns (LaunchRouter launchRouter)
    {
        (address deployed,) = deployIfNeeded(
            abi.encodePacked(type(LaunchRouter).creationCode, abi.encode(core, extension)),
            salt,
            expected,
            "LaunchRouter"
        );
        launchRouter = LaunchRouter(deployed);
        if (launchRouter.EXTENSION() != extension || launchRouter.LIQUIDITY() != extension.LIQUIDITY()) {
            revert RouterMismatch(deployed);
        }
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
