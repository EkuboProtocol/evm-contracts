// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {BaseForwardee} from "../../src/base/BaseForwardee.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {IFlashAccountant, IForwardee} from "../../src/interfaces/IFlashAccountant.sol";
import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {Locker} from "../../src/types/locker.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";

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

function lockAgainAction(Actor actor, Action[] memory actions) pure returns (Action memory) {
    return Action(4, abi.encode(actor, actions));
}

function emitEventAction(bytes memory data) pure returns (Action memory) {
    return Action(5, data);
}

function forwardActions(IForwardee forwardee, Action[] memory actions) pure returns (Action memory) {
    return Action(6, abi.encode(forwardee, actions));
}

contract Actor is BaseLocker, BaseForwardee {
    using FlashAccountantLib for *;

    constructor(Accountant accountant) BaseLocker(accountant) BaseForwardee(accountant) {}

    function doStuff(Action[] calldata actions) external returns (bytes[] memory results) {
        results = abi.decode(lock(abi.encode(msg.sender, actions)), (bytes[]));
    }

    error IdMismatch(uint256 id, uint256 expected);
    error SenderMismatch(address sender, address expected);

    event EventAction(bytes data);

    function execute(uint256 lockerId, address sender, Action[] memory actions)
        internal
        returns (bytes[] memory results)
    {
        results = new bytes[](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            Action memory a = actions[i];
            // asserts the id
            if (a.kind == 0) {
                uint256 expected = abi.decode(a.data, (uint256));
                if (lockerId != expected) revert IdMismatch(lockerId, expected);
            } else if (a.kind == 1) {
                address expected = abi.decode(a.data, (address));
                if (sender != expected) revert SenderMismatch(sender, expected);
            } else if (a.kind == 2) {
                (address token, uint128 amount, address recipient) = abi.decode(a.data, (address, uint128, address));
                if (amount > 0) {
                    ACCOUNTANT.withdraw(token, recipient, amount);
                }
            } else if (a.kind == 3) {
                (address from, address token, uint256 amount) = abi.decode(a.data, (address, address, uint256));
                if (amount != 0) {
                    if (token == NATIVE_TOKEN_ADDRESS) {
                        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
                    } else {
                        ACCOUNTANT.payFrom(from, token, amount);
                    }
                }
            } else if (a.kind == 4) {
                (Actor actor, Action[] memory nestedActions) = abi.decode(a.data, (Actor, Action[]));
                results[i] = abi.encode(actor.doStuff(nestedActions));
            } else if (a.kind == 5) {
                emit EventAction(a.data);
            } else if (a.kind == 6) {
                (address forwardee, Action[] memory nestedActions) = abi.decode(a.data, (address, Action[]));
                results[i] = FlashAccountantLib.forward(ACCOUNTANT, forwardee, abi.encode(nestedActions));
            } else {
                revert("unrecognized");
            }
        }
    }

    function handleLockData(uint256 id, bytes memory data) internal override returns (bytes memory result) {
        Locker locker = Accountant(payable(ACCOUNTANT)).getLocker();
        (uint256 lockerId, address lockerAddr) = locker.parse();
        assert(lockerId == id);
        assert(lockerAddr == address(this));

        (address sender, Action[] memory actions) = abi.decode(data, (address, Action[]));

        result = abi.encode(execute(id, sender, actions));
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        // forwardee is the locker now
        Locker locker = Accountant(payable(ACCOUNTANT)).getLocker();
        (uint256 lockerId, address lockerAddr) = locker.parse();
        assert(lockerId == original.id());
        assert(lockerAddr == address(this));

        Action[] memory actions = abi.decode(data, (Action[]));

        result = abi.encode(execute(lockerId, original.addr(), actions));
    }

    receive() external payable {}
}

contract Accountant is FlashAccountant {
    function getLocker() external view returns (Locker locker) {
        locker = _getLocker();
    }
}

contract FlashAccountantTest is Test {
    Accountant public accountant;
    Actor public actor;

    function setUp() public {
        accountant = new Accountant();
        actor = new Actor(accountant);
    }

    function test_callbacksByAccountantOnly() public {
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        actor.locked(0);
        vm.expectRevert(BaseForwardee.BaseForwardeeAccountantOnly.selector);
        actor.forwarded(Locker.wrap(bytes32(0)));
    }

    function test_assertIdStartsAtZero() public {
        Action[] memory actions = new Action[](1);
        actions[0] = assertIdAction(0);
        actor.doStuff(actions);
        actions[0] = assertIdAction(1);
        vm.expectRevert(abi.encodeWithSelector(Actor.IdMismatch.selector, 0, 1), address(actor));
        actor.doStuff(actions);
    }

    function test_assertSenderIsEncoded() public {
        Action[] memory actions = new Action[](1);
        actions[0] = assertSender(address(this));
        actor.doStuff(actions);
        actions[0] = assertSender(address(0xdeadbeef));
        vm.expectRevert(
            abi.encodeWithSelector(Actor.SenderMismatch.selector, address(this), address(0xdeadbeef)), address(actor)
        );
        actor.doStuff(actions);
    }

    function test_flashLoan_revertsIfNotPaidBack() public {
        vm.deal(address(accountant), 100);
        Action[] memory actions = new Action[](1);
        actions[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 50, address(0xdeadbeef));
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0), address(accountant));
        actor.doStuff(actions);
    }

    function test_flashLoan_in_forward_reverts_if_not_paid_back() public {
        vm.deal(address(accountant), 100);
        Action[] memory inner = new Action[](1);
        inner[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 1, address(0xdeadbeef));
        Action[] memory outer = new Action[](1);
        outer[0] = forwardActions(actor, inner);
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0), address(accountant));
        actor.doStuff(outer);
    }

    function test_flashLoan_in_forward_succeeds_if_paid_back() public {
        vm.deal(address(accountant), 100);
        Action[] memory inner = new Action[](1);
        inner[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 1, address(0xdeadbeef));
        Action[] memory outer = new Action[](2);
        outer[0] = forwardActions(actor, inner);
        outer[1] = payAction(address(0), NATIVE_TOKEN_ADDRESS, 1);
        vm.deal(address(actor), 1);
        actor.doStuff(outer);
    }

    function test_flashLoan_succeedsIfPaidBack() public {
        vm.deal(address(accountant), 100);

        Action[] memory actions = new Action[](3);
        actions[0] = withdrawAction(NATIVE_TOKEN_ADDRESS, 50, address(actor));
        actions[1] = payAction(address(0), NATIVE_TOKEN_ADDRESS, 30);
        actions[2] = payAction(address(0), NATIVE_TOKEN_ADDRESS, 20);
        actor.doStuff(actions);
    }

    function test_nested_locks_correctSender() public {
        vm.deal(address(accountant), 100);

        Actor actor0 = actor;
        Actor actor1 = new Actor(accountant);
        Actor actor2 = new Actor(accountant);

        Action[] memory actions2 = new Action[](3);
        // forwarded lock, same id
        actions2[0] = assertIdAction(1);
        actions2[1] = assertSender(address(actor1));
        actions2[2] = emitEventAction("hello");

        Action[] memory actions1 = new Action[](3);
        actions1[0] = assertIdAction(1);
        actions1[1] = assertSender(address(actor0));
        actions1[2] = forwardActions(actor2, actions2);

        Action[] memory actions0 = new Action[](3);
        actions0[0] = assertIdAction(0);
        actions0[1] = assertSender(address(this));
        actions0[2] = lockAgainAction(actor1, actions1);

        vm.expectEmit(address(actor2));
        emit Actor.EventAction("hello");

        actor.doStuff(actions0);
    }

    function test_arbitraryNesting(uint256 depth, uint256 underpayAtDepth) public {
        vm.deal(address(accountant), type(uint64).max);
        depth = bound(depth, 0, 32);
        underpayAtDepth = bound(underpayAtDepth, 0, depth * 2);

        vm.expectEmit(address(actor));

        Action[] memory actions = new Action[](0);
        while (true) {
            Action[] memory temp = new Action[](6);
            temp[0] = assertIdAction(depth);
            temp[1] = assertSender(depth == 0 ? address(this) : address(actor));

            uint128 randomFlashLoanAmount = uint128(bound(uint256(keccak256(abi.encode(depth))), 1, type(uint32).max));
            temp[2] = withdrawAction(NATIVE_TOKEN_ADDRESS, randomFlashLoanAmount, address(actor));

            temp[3] = lockAgainAction(actor, actions);

            if (underpayAtDepth == depth) {
                vm.expectRevert(
                    abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, underpayAtDepth),
                    address(accountant)
                );
                uint128 randomUnderpayAmount =
                    uint128(bound(uint256(keccak256(abi.encode(depth + 1))), 0, randomFlashLoanAmount - 1));
                temp[4] = payAction(address(0), NATIVE_TOKEN_ADDRESS, randomUnderpayAmount);
            } else {
                temp[4] = payAction(address(0), NATIVE_TOKEN_ADDRESS, randomFlashLoanAmount);
            }

            temp[5] = emitEventAction(abi.encode(depth));
            emit Actor.EventAction(abi.encode(depth));

            actions = temp;

            if (depth == 0) break;
            depth -= 1;
        }

        actor.doStuff(actions);
    }
}
