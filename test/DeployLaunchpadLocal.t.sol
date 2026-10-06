// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {DeployScheduledLaunch} from "../script/DeployScheduledLaunch.s.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";

contract DeployScheduledLaunchHarness is DeployScheduledLaunch {
    function checkTwamm(ICore core, address twamm, ScheduledLaunch extension) external view returns (bool) {
        return _checkTwamm(core, twamm, extension);
    }

    function deployRouter(ICore core, ScheduledLaunch extension, bytes32 salt) external returns (LaunchRouter) {
        return _deployRouter(core, extension, salt, address(0));
    }
}

/// Deployment proves the extension's terminal-pool TWAMM before the manifest records twamm_registered.
contract DeployLaunchpadLocalTest is ScheduledLaunchTest {
    DeployScheduledLaunchHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new DeployScheduledLaunchHarness();
    }

    /// The router is the third deployed contract, bound to the extension and its liquidity contract, at a
    /// CREATE2 address predicted from the salt; a second run finds it instead of redeploying.
    function test_routerDeploysBoundToExtension() public {
        bytes32 salt = keccak256("router");
        LaunchRouter deployed = harness.deployRouter(core, extension, salt);
        assertEq(address(deployed.EXTENSION()), address(extension));
        assertEq(address(deployed.LIQUIDITY()), address(vault));
        assertEq(address(harness.deployRouter(core, extension, salt)), address(deployed));
    }

    function test_twammCheckPasses() public view {
        assertTrue(harness.checkTwamm(core, address(twamm), extension));
    }

    function test_twammCheckRejectsManifestMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployScheduledLaunch.TwammMismatch.selector, address(0x1234), address(twamm))
        );
        harness.checkTwamm(core, address(0x1234), extension);
    }

    function test_twammCheckRejectsUnregisteredTwamm() public {
        // A launch extension pointed at an address Core does not know as an extension.
        address unregistered = address(0x7777);
        address target = address((uint160(scheduledLaunchCallPoints().toUint8()) << 152) | 1);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core, unregistered), target);
        vm.expectRevert(abi.encodeWithSelector(DeployScheduledLaunch.TwammNotRegistered.selector, unregistered));
        harness.checkTwamm(core, unregistered, ScheduledLaunch(target));
    }
}
