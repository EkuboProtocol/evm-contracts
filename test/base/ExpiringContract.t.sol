// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExpiringContract} from "../../src/base/ExpiringContract.sol";

contract TestTarget is ExpiringContract {
    uint256 public x;

    constructor(uint256 expirationTime) ExpiringContract(expirationTime) {}

    function protectedIf(bool enforce) external expiresIff(enforce) {
        x++;
    }

    function protected() external expires {
        x++;
    }

    function unprotected() external {
        x++;
    }
}

contract ExpiringContractTest is Test {
    function test_unprotected_neverReverts(uint256 timestamp, uint256 expires) public {
        TestTarget tt = new TestTarget(expires);
        vm.warp(timestamp);
        assertEq(tt.x(), 0);
        tt.unprotected();
        assertEq(tt.x(), 1);
    }

    function test_protected_revertsIfAfterExpires(uint256 timestamp, uint256 expires) public {
        TestTarget tt = new TestTarget(expires);
        vm.warp(timestamp);
        if (timestamp > expires) {
            vm.expectRevert(ExpiringContract.ContractHasExpired.selector);
            tt.protected();
            assertEq(tt.x(), 0);
        } else {
            tt.protected();
            assertEq(tt.x(), 1);
        }
    }

    function test_protected_revertsIfAfterExpires_andEnforce(uint256 timestamp, uint256 expires, bool enforce) public {
        TestTarget tt = new TestTarget(expires);
        vm.warp(timestamp);
        if (enforce && timestamp > expires) {
            vm.expectRevert(ExpiringContract.ContractHasExpired.selector);
            tt.protectedIf(enforce);
            assertEq(tt.x(), 0);
        } else {
            tt.protectedIf(enforce);
            assertEq(tt.x(), 1);
        }
    }
}
