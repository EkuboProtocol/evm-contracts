// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ILocker, IForwardee, IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";

/**
 * @notice A simple target that extends FlashAccountant to allow `borrow` and `pay`.
 */
contract TestTarget is FlashAccountant {
    function borrow(address token, uint128 amount) external {
        _requireLocker();
        _accountDebt(_lockerId(), token, int256(uint256(amount)));
    }

    function pay(address token, uint128 amount) external {
        _requireLocker();
        _accountDebt(_lockerId(), token, -int256(uint256(amount)));
    }

    function _lockerId() internal view returns (uint256) {
        (uint256 id,) = _getLocker();
        return id;
    }
}

/**
 * @notice A basic locker that, in `locked(...)`, borrows an amount and optionally forwards.
 * @dev Data encodes (bool runForward, address token, uint128 borrowAmount, uint128 payAmount).
 */
abstract contract LockerTester is ILocker {
    address public target;
    address public forwardee;

    constructor(address _target, address _forwardee) {
        target = _target;
        forwardee = _forwardee;
    }

    // Default to no-op
    function locked(uint256, /*id*/ bytes calldata /*data*/ ) external virtual override returns (bytes memory) {
        return bytes("");
    }
}

/**
 * @notice A basic forwardee that, in `forwarded(...)`, can also borrow/pay from the context.
 *         Data encodes (address token, uint128 borrowAmount, uint128 payAmount).
 */
abstract contract ForwardeeTester is IForwardee {
    address public target;

    constructor(address _target) {
        target = _target;
    }

    // Default to no-op
    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata /*data*/ )
        external
        virtual
        override
        returns (bytes memory)
    {
        return bytes("");
    }
}

/**
 * @notice Concrete locker that borrows, optionally forwards, then pays.
 */
contract LockerTesterImpl is LockerTester {
    constructor(address _target, address _forwardee) LockerTester(_target, _forwardee) {}

    // Data => (bool runForward, address token, uint128 borrowAmount, uint128 payAmount)
    function locked(uint256, /*id*/ bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == target, "LockerTesterImpl: not called by target");

        (bool runForward, address token, uint128 borrowAmount, uint128 payAmount) =
            abi.decode(data, (bool, address, uint128, uint128));

        // Borrow
        TestTarget(target).borrow(token, borrowAmount);

        // Forward
        if (runForward) {
            // forwardee reads its own data from the forwarded(...) call
            IFlashAccountant(target).forward(forwardee, abi.encode(token, borrowAmount, payAmount));
        }

        // Pay
        if (payAmount > 0) {
            TestTarget(target).pay(token, payAmount);
        }

        return "";
    }
}

/**
 * @notice Concrete forwardee that can borrow/pay from the forwarded context.
 * @dev Data => (address token, uint128 borrowAmount, uint128 payAmount).
 */
contract ForwardeeTesterImpl is ForwardeeTester {
    constructor(address _target) ForwardeeTester(_target) {}

    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == target, "ForwardeeTesterImpl: not called by target");

        (address token, uint128 borrowAmount, uint128 payAmount) = abi.decode(data, (address, uint128, uint128));

        // Forwardee can do additional borrowing/paying
        if (borrowAmount > 0) {
            TestTarget(target).borrow(token, borrowAmount / 2);
        }
        if (payAmount > 0) {
            TestTarget(target).pay(token, payAmount / 2);
        }

        return "";
    }
}

/**
 * @notice The core single-level test suite with new tests
 *         showing the forwardee can also do borrow/pay calls.
 */
contract FlashAccountantTest is Test {
    TestTarget public target;
    LockerTesterImpl public lockerImpl;
    ForwardeeTesterImpl public forwarderImpl;
    address public someToken = address(0xAAA);

    function setUp() public {
        target = new TestTarget();
        forwarderImpl = new ForwardeeTesterImpl(address(target));
        lockerImpl = new LockerTesterImpl(address(target), address(forwarderImpl));
    }

    // Basic checks: can't borrow, pay, or forward outside a lock
    function test_cannotBorrowWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.borrow(someToken, 100);
    }

    function test_cannotPayWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.pay(someToken, 100);
    }

    function test_cannotForwardWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.forward(address(forwarderImpl), "");
    }

    // Only the current locker can manipulate debt
    function test_onlyLockerCanBorrowInsideLock() public {
        vm.startPrank(address(lockerImpl));
        // net zero => no revert
        bytes memory data = abi.encode(false, someToken, uint128(100), uint128(100));
        target.lock(data);
        vm.stopPrank();

        // no lock is active
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.borrow(someToken, 1);
    }

    // Show the forwardee can also do borrow/pay, and final net must still be zero.
    function test_forwardeeCanBorrowAndPayInForward() public {
        /**
         * Scenario:
         *        1) Locker borrows 100.
         *        2) Forward to forwarder who does .borrow(100/2=50) and pay(0? => let's do something).
         *        3) Then locker pays 150.
         *
         *      Net effect => 100 + 50 borrowed, 150 paid => zero => success.
         *      Let's have the forwarder do a partial pay as well to demonstrate it can do both.
         */

        // We'll encode payAmount=0 for the Locker, so the locker does not pay yet.
        // We'll rely on the forwarder to do partial pay, then the locker does a final pay at the end.
        // We'll do something like: final pay from the locker is 130 instead of 150, so net is 20 short.
        // Then the forwarder also does 20 pay => net = 0. Let's keep it simpler:

        // We'll do this:
        //   Locker: borrow=100, pay=130, forward => forwarder: borrow=50, pay=20 => final net = ?
        //   total borrowed=100 + 50=150, total paid=130 + 20=150 => net=0 => success

        bytes memory data = abi.encode(true, someToken, uint128(100), uint128(130));

        // We'll customize the forwarder call. We'll do that by adjusting the forwarder to read (borrow=100, pay=130),
        // which means forwarder borrows=100/2=50, pays=130/2=65 => that would break our final net unless we pay more from locker.
        // Let's just run with it and see if it net=0:

        // Net from locker: +100 -130 = -30
        // Net from forwarder: +50 -65 = -15
        // total net = -45 => not zero, that would revert. So let's fix it:

        // Let's do pay=100 in the data, so forwarder also sees pay=100 => partial pay=50
        // Now the net from locker => +100 -100= 0
        // Net from forwarder => +50 -50= 0 => total net=0 => success

        data = abi.encode(true, someToken, uint128(100), uint128(100));

        vm.prank(address(lockerImpl));
        // Should not revert if net=0
        target.lock(data);
    }

    // Show that the forwardee cannot call borrow/pay if it's *not* in a forwarded context
    function test_forwardeeCannotBorrowOutsideForward() public {
        // Trying from the forwardee outside a forwarded context => revert NotLocked
        vm.startPrank(address(forwarderImpl));
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.borrow(someToken, 50);

        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.pay(someToken, 50);
        vm.stopPrank();
    }

    // Single-level fuzz test: final net must be zero or revert
    function testFuzz_lockZeroDebt(bool runForward, uint128 borrowAmount, uint128 payAmount) public {
        uint256 b = borrowAmount;
        uint256 p = payAmount;

        uint256 finalBorrow = b + (runForward ? b / 2 : 0);
        uint256 finalPay = p + (runForward ? p / 2 : 0);

        bytes memory data = abi.encode(runForward, someToken, borrowAmount, payAmount);

        vm.prank(address(lockerImpl));
        if (finalBorrow != finalPay) {
            vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
            target.lock(data);
        } else {
            target.lock(data);
        }
    }

    // Multi-lock test in sequence (no recursion)
    function test_nestedLockingAndForwarding() public {
        bytes memory data = abi.encode(true, someToken, uint128(100), uint128(100));
        vm.prank(address(lockerImpl));
        target.lock(data);

        data = abi.encode(true, someToken, uint128(200), uint128(100));
        vm.prank(address(lockerImpl));
        vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
        target.lock(data);

        data = abi.encode(true, someToken, uint128(300), uint128(300));
        vm.prank(address(lockerImpl));
        target.lock(data);
    }
}
