// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ILocker, IForwardee} from "../../src/interfaces/IFlashAccountant.sol";

abstract contract LockerTester is ILocker {
// todo: implement what you need here
}

abstract contract ForwardeeTester is IForwardee {
// todo: implement what you need here
}

// This contract has borrow and pay methods that mock how other contracts might use the flash accountant base contract
contract TestTarget is FlashAccountant {
    function borrow(address token, uint128 amount) external {
        (uint256 id, address locker) = _requireLocker();
        _accountDebt(id, token, int256(uint256(amount)));
    }

    function pay(address token, uint128 amount) external {
        (uint256 id, address locker) = _requireLocker();
        _accountDebt(id, token, -int256(uint256(amount)));
    }

    function getDebt(uint256 id, address token) external returns (int256 debt) {
        debt = _getDebt(id, token);
    }

    function getLocker() external view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
    }
}

contract FlashAccountantTest is Test {
    TestTarget target;

    function setUp() public {
        target = new TestTarget();
    }

    function test_nestedLockingAndForwarding() public {
        // todo: make this a fuzz test (add parameters to the function) that thoroughly tests the expected behavior of the flash accountant
    }
}
