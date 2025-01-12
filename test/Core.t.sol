// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
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

    function test_core_lock_only_via_proxy() public {
        vm.expectRevert(UUPSUpgradeable.UnauthorizedCallContext.selector);
        Core(implementation).lock(hex"");
    }
}
