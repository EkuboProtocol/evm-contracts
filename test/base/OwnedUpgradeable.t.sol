// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {OwnedUpgradeable} from "../../src/base/OwnedUpgradeable.sol";

contract OwnedUpgradeableTestContract is OwnedUpgradeable {
    function onlyProxyFunc() external onlyProxy {}
    function func() external {}
}

contract OwnedUpgradeableTest is Test {
    address public implementation;
    OwnedUpgradeableTestContract public owned;

    function setUp() public {
        implementation = address(new OwnedUpgradeableTestContract());
        owned = OwnedUpgradeableTestContract(LibClone.deployERC1967(implementation));
    }

    function test_deployed_state() public {
        owned.initialize(address(123));
        assertEq(owned.owner(), address(123));
    }

    function test_guard_initialize() public {
        owned.initialize(address(123));
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        owned.initialize(address(234));
    }

    function test_upgrade_only_by_owner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        owned.upgradeToAndCall(address(234), hex"");
    }

    function test_upgrade_new_contract() public {
        owned.initialize(address(123));
        address newImplementation = address(new OwnedUpgradeableTestContract());
        assertEq(owned.getImplementation(), implementation);
        changePrank(address(123));
        owned.upgradeToAndCall(newImplementation, hex"");
        assertEq(owned.getImplementation(), newImplementation);
    }

    function test_gas_setX_via_proxy() public {
        vm.startSnapshotGas("proxy");
        owned.onlyProxyFunc();
        vm.stopSnapshotGas();

        vm.startSnapshotGas("proxy repeat");
        owned.onlyProxyFunc();
        vm.stopSnapshotGas();
    }

    function test_gas_setX_direct() public {
        vm.startSnapshotGas("direct");
        OwnedUpgradeableTestContract(implementation).func();
        vm.stopSnapshotGas();

        vm.startSnapshotGas("direct repeat");
        OwnedUpgradeableTestContract(implementation).func();
        vm.stopSnapshotGas();
    }
}
