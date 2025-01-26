// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {IFlashAccountant, NATIVE_TOKEN_ADDRESS} from "../../src/interfaces/IFlashAccountant.sol";
import {FlashAccountant} from "../../src/base/FlashAccountant.sol";

struct Action {
    uint8 kind;
    bytes data;
}

function assertIdAction(uint256 id) pure returns (Action memory) {
    return Action(0, abi.encode(id));
}

function assertSender(address sender) pure returns (Action memory) {
    return Action(1, abi.encode(sender));
}

function withdrawAction(address token, uint128 amount, address recipient) pure returns (Action memory) {
    return Action(2, abi.encode(token, amount, recipient));
}

function payAction(address from, address token, uint256 amount) pure returns (Action memory) {
    return Action(3, abi.encode(from, token, amount));
}

function lockAgainAction(Action[] memory actions) pure returns (Action memory) {
    return Action(4, abi.encode(actions));
}

contract ExampleLocker is BaseLocker {
    constructor(Target accountant) BaseLocker(accountant) {}

    function doStuff(Action[] calldata actions) external returns (bytes[] memory results) {
        results = abi.decode(lock(abi.encode(msg.sender, actions)), (bytes[]));
    }

    error IdMismatch(uint256 id, uint256 expected);
    error SenderMismatch(address sender, address expected);

    function handleLockData(bytes memory data) internal override returns (bytes memory result) {
        (uint256 id, address locker) = Target(payable(accountant)).getLocker();
        assert(locker == address(this));

        (address sender, Action[] memory actions) = abi.decode(data, (address, Action[]));

        bytes[] memory results = new bytes[](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            Action memory a = actions[i];
            // asserts the id
            if (a.kind == 0) {
                uint256 expected = abi.decode(a.data, (uint256));
                if (id != expected) revert IdMismatch(id, expected);
            } else if (a.kind == 1) {
                address expected = abi.decode(a.data, (address));
                if (sender != expected) revert SenderMismatch(sender, expected);
            } else if (a.kind == 2) {
                (address token, uint128 amount, address recipient) = abi.decode(a.data, (address, uint128, address));
                withdraw(token, amount, recipient);
            } else if (a.kind == 3) {
                (address from, address token, uint256 amount) = abi.decode(a.data, (address, address, uint256));
                pay(from, token, amount);
            } else if (a.kind == 4) {
                Action[] memory nestedActions = abi.decode(a.data, (Action[]));
                results[i] = abi.encode(this.doStuff(nestedActions));
            } else {
                revert("unrecognized");
            }
        }

        result = abi.encode(results);
    }

    receive() external payable {}
}

contract Target is FlashAccountant {
    function getLocker() external view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
    }
}

contract FlashAccountantTest is Test {
    Target public target;
    ExampleLocker public locker;

    function setUp() public {
        target = new Target();
        locker = new ExampleLocker(target);
    }

    function test_assertIdStartsAtZero() public {
        Action[] memory actions = new Action[](1);
        actions[0] = assertIdAction(0);
        locker.doStuff(actions);
        actions[0] = assertIdAction(1);
        vm.expectRevert(abi.encodeWithSelector(ExampleLocker.IdMismatch.selector, 0, 1), address(locker));
        locker.doStuff(actions);
    }

    function test_assertSenderIsEncoded() public {
        Action[] memory actions = new Action[](1);
        actions[0] = assertSender(address(this));
        locker.doStuff(actions);
        actions[0] = assertSender(address(0xdeadbeef));
        vm.expectRevert(
            abi.encodeWithSelector(ExampleLocker.SenderMismatch.selector, address(this), address(0xdeadbeef)),
            address(locker)
        );
        locker.doStuff(actions);
    }

    function test_flashLoan_revertsIfNotPaidBack() public {
        vm.deal(address(target), 100);
        Action[] memory actions = new Action[](1);
        actions[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 50, address(0xdeadbeef));
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector), address(target));
        locker.doStuff(actions);
    }

    function test_flashLoan_succeedsIfPaidBack() public {
        vm.deal(address(target), 100);

        Action[] memory actions = new Action[](3);
        actions[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 50, address(locker));
        actions[1] = payAction(address(0), NATIVE_TOKEN_ADDRESS, 30);
        actions[2] = payAction(address(0), NATIVE_TOKEN_ADDRESS, 20);
        locker.doStuff(actions);
    }

    function test_arbitraryNesting(uint8 depth) public {
        Action[] memory actions = new Action[](0);
        while (true) {
            Action[] memory temp = new Action[](5);
            temp[0] = assertIdAction(depth);
            temp[1] = assertSender(address(locker));

            uint128 randomFlashLoanAmount = uint128(bound(uint256(keccak256(abi.encode(depth))), 0, type(uint32).max));
            temp[2] = withdrawAction(NATIVE_TOKEN_ADDRESS, randomFlashLoanAmount, address(locker));
            temp[3] = payAction(address(0), NATIVE_TOKEN_ADDRESS, randomFlashLoanAmount);

            temp[4] = lockAgainAction(actions);

            if (depth == 0) break;
            depth -= 1;
        }
        locker.doStuff(actions);
    }
}
