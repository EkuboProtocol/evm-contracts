// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {ICore} from "../../src/interfaces/ICore.sol";

contract TestTarget is UsesCore {
    uint256 public x;

    constructor(ICore core) UsesCore(core) {}

    function protected() public onlyCore {
        x++;
    }

    function unprotected() public {
        x++;
    }
}

contract UsesCoreTest is Test {
    function test_unprotected_neverReverts(address core, address caller) public {
        TestTarget tt = new TestTarget(ICore(payable(core)));
        assertEq(tt.x(), 0);
        vm.prank(caller);
        tt.unprotected();
        assertEq(tt.x(), 1);
    }

    function test_protected_revertsIfNotCore(address core, address caller) public {
        vm.assume(caller != core);

        TestTarget tt = new TestTarget(ICore(payable(core)));
        vm.prank(caller);
        vm.expectRevert(UsesCore.CoreOnly.selector);
        tt.protected();
        assertEq(tt.x(), 0);
    }

    function test_protected_callableByCore(address core) public {
        TestTarget tt = new TestTarget(ICore(payable(core)));
        assertEq(tt.x(), 0);
        vm.prank(core);
        tt.protected();
        assertEq(tt.x(), 1);
    }
}
