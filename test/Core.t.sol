// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {CoreProxyDeployer} from "../src/CoreProxyDeployer.sol";

contract CoreTest is Test {
    address public implementation;
    Core public core;
    CoreProxyDeployer public deployer;

    function setUp() public {
        implementation = address(new Core());
        deployer = new CoreProxyDeployer(implementation, address(123));
        core = deployer.core();
    }

    function test_deployed_state() public view {
        assertEq(core.owner(), address(123));
    }

    function test_guard_initialize() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        core.initialize(address(234));
    }

    function test_upgrade_only_by_owner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        core.upgradeToAndCall(address(234), hex"");
    }

    function test_upgrade_new_contract() public {
        address newImplementation = address(new Core());
        assertEq(core.getImplementation(), implementation);
        changePrank(address(123));
        core.upgradeToAndCall(newImplementation, hex"");
        assertEq(core.getImplementation(), newImplementation);
    }
}
