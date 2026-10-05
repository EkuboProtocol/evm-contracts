// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {DeployScheduledLaunch} from "../script/DeployScheduledLaunch.s.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {ICore} from "../src/interfaces/ICore.sol";

contract DeployScheduledLaunchHarness is DeployScheduledLaunch {
    function checkTwamm(ICore core, address twamm, ScheduledLaunch extension) external view returns (bool) {
        return _checkTwamm(core, twamm, extension);
    }
}

/// Deployment proves the extension's terminal-pool TWAMM before the manifest records twamm_registered.
contract DeployLaunchpadLocalTest is ScheduledLaunchTest {
    DeployScheduledLaunchHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new DeployScheduledLaunchHarness();
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
