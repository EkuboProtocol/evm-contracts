// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {BaseOwnableExecutor} from "../../src/base/BaseOwnableExecutor.sol";

contract BaseOwnableExecutorHarness is BaseOwnableExecutor {
    uint256 public number;

    constructor(address owner) BaseOwnableExecutor(owner) {}

    function setNumber(uint256 newNumber) external {
        number = newNumber;
    }
}

contract CallTarget {
    uint256 public number;

    function setNumber(uint256 newNumber) external payable returns (uint256) {
        number = newNumber;
        return newNumber;
    }
}

contract DelegateCallTarget {
    uint256 public number;

    function setNumber(uint256 newNumber) external returns (uint256) {
        number = newNumber;
        return newNumber;
    }

    function self() external view returns (address) {
        return address(this);
    }
}

contract RevertTarget {
    error RevertError(uint256 value);

    function fail(uint256 value) external pure {
        revert RevertError(value);
    }
}

contract BaseOwnableExecutorTest is Test {
    BaseOwnableExecutorHarness executor;
    CallTarget callTarget;
    DelegateCallTarget delegateCallTarget;
    RevertTarget revertTarget;

    function setUp() public {
        executor = new BaseOwnableExecutorHarness(address(this));
        callTarget = new CallTarget();
        delegateCallTarget = new DelegateCallTarget();
        revertTarget = new RevertTarget();
    }

    function test_constructor_sets_owner() public view {
        assertEq(executor.owner(), address(this));
    }

    function test_call_forwards_call_from_proxy() public {
        bytes memory result = executor.call(address(callTarget), 0, abi.encodeCall(CallTarget.setNumber, (123)));

        assertEq(abi.decode(result, (uint256)), 123);
        assertEq(callTarget.number(), 123);
    }

    function test_call_fails_if_not_owner() public {
        vm.prank(address(0xdeadbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.call(address(callTarget), 0, abi.encodeCall(CallTarget.setNumber, (123)));
    }

    function test_call_bubbles_revert() public {
        vm.expectRevert(abi.encodeWithSelector(RevertTarget.RevertError.selector, 7));
        executor.call(address(revertTarget), 0, abi.encodeCall(RevertTarget.fail, (7)));
    }

    function test_delegate_call_executes_in_proxy_context() public {
        bytes memory result =
            executor.delegateCall(address(delegateCallTarget), abi.encodeCall(DelegateCallTarget.setNumber, (456)));

        assertEq(abi.decode(result, (uint256)), 456);
        assertEq(executor.number(), 456);
        assertEq(delegateCallTarget.number(), 0);
    }

    function test_delegate_call_returns_proxy_address_for_address_this() public {
        bytes memory result =
            executor.delegateCall(address(delegateCallTarget), abi.encodeCall(DelegateCallTarget.self, ()));

        assertEq(abi.decode(result, (address)), address(executor));
    }

    function test_delegate_call_fails_if_not_owner() public {
        vm.prank(address(0xdeadbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.delegateCall(address(delegateCallTarget), abi.encodeCall(DelegateCallTarget.setNumber, (456)));
    }

    function test_delegate_call_bubbles_revert() public {
        vm.expectRevert(abi.encodeWithSelector(RevertTarget.RevertError.selector, 9));
        executor.delegateCall(address(revertTarget), abi.encodeCall(RevertTarget.fail, (9)));
    }
}
