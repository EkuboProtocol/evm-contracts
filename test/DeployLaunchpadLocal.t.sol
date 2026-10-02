// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {DeployLaunchpadLocal} from "../script/DeployLaunchpadLocal.s.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {ICore} from "../src/interfaces/ICore.sol";

contract DeployLaunchpadLocalHarness is DeployLaunchpadLocal {
    function checkTwamm(ICore core, address twamm, ScheduledLaunch extension, LaunchRouter launchRouter)
        external
        view
        returns (bool)
    {
        return _checkTwamm(core, twamm, extension, launchRouter);
    }
}

/// The manifest's twamm_registered is written only after the deployed contracts prove it.
contract DeployLaunchpadLocalTest is ScheduledLaunchTest {
    DeployLaunchpadLocalHarness harness;
    LaunchRouter launchRouter;

    function setUp() public override {
        super.setUp();
        harness = new DeployLaunchpadLocalHarness();
        launchRouter = new LaunchRouter(core, extension);
    }

    function test_twammCheckPasses() public view {
        assertTrue(harness.checkTwamm(core, address(twamm), extension, launchRouter));
    }

    function test_twammCheckRejectsManifestMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployLaunchpadLocal.TwammMismatch.selector, address(0x1234), address(twamm))
        );
        harness.checkTwamm(core, address(0x1234), extension, launchRouter);
    }

    function test_twammCheckRejectsUnregisteredTwamm() public {
        // A launch extension pointed at an address Core does not know as an extension.
        address unregistered = address(0x7777);
        address target = address((uint160(scheduledLaunchCallPoints().toUint8()) << 152) | 1);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core, unregistered), target);
        ScheduledLaunch other = ScheduledLaunch(target);
        vm.expectRevert(abi.encodeWithSelector(DeployLaunchpadLocal.TwammNotRegistered.selector, unregistered));
        harness.checkTwamm(core, unregistered, other, new LaunchRouter(core, other));
    }

    function test_twammCheckRejectsRouterForAnotherExtension() public {
        address target = address((uint160(scheduledLaunchCallPoints().toUint8()) << 152) | 2);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core, address(twamm)), target);
        ScheduledLaunch other = ScheduledLaunch(target);
        vm.expectRevert(
            abi.encodeWithSelector(DeployLaunchpadLocal.ExtensionMismatch.selector, address(other), address(extension))
        );
        harness.checkTwamm(core, address(twamm), other, launchRouter);
    }
}
