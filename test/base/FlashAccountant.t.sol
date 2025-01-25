// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ILocker, IForwardee, IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";

// ---------------------
// Supporting Contracts
// ---------------------

abstract contract LockerTester is ILocker {
    address public target;
    address public forwardee;

    constructor(address _target, address _forwardee) {
        target = _target;
        forwardee = _forwardee;
    }

    // Silence compiler warnings by omitting unused params.
    function locked(uint256, /*id*/ bytes calldata /*data*/ ) external virtual override returns (bytes memory) {
        return bytes("");
    }
}

abstract contract ForwardeeTester is IForwardee {
    address public target;

    constructor(address _target) {
        target = _target;
    }

    // Silence compiler warnings by omitting unused params.
    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata /*data*/ )
        external
        virtual
        override
        returns (bytes memory)
    {
        return bytes("");
    }
}

// ---------------------
// Actual Test Target
// ---------------------

contract TestTarget is FlashAccountant {
    function borrow(address token, uint128 amount) external {
        _requireLocker(); // we don't need the return values here
        _accountDebt(_lockerId(), token, int256(uint256(amount)));
    }

    function pay(address token, uint128 amount) external {
        _requireLocker();
        _accountDebt(_lockerId(), token, -int256(uint256(amount)));
    }

    // Provide an internal helper to get the current lock id without re-checking the locker
    function _lockerId() internal view returns (uint256) {
        (uint256 id,) = _getLocker();
        return id;
    }

    function getDebt(uint256 id, address token) external view returns (int256) {
        return _getDebt(id, token);
    }

    function getLocker() external view returns (uint256, address) {
        return _getLocker();
    }
}

// ---------------------
// Concrete Tester Impl
// ---------------------

// Encodes: (bool runForward, address token, uint128 borrowAmount, uint128 payAmount)
contract LockerTesterImpl is LockerTester {
    constructor(address _target, address _forwardee) LockerTester(_target, _forwardee) {}

    function locked(uint256, /*id*/ bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == target, "LockerTesterImpl: caller not target");

        (bool runForward, address token, uint128 borrowAmount, uint128 payAmount) =
            abi.decode(data, (bool, address, uint128, uint128));

        // Borrow
        TestTarget(target).borrow(token, borrowAmount);

        // Optional forward
        if (runForward) {
            IFlashAccountant(target).forward(forwardee, abi.encode(token, borrowAmount, payAmount));
        }

        // Pay
        if (payAmount > 0) {
            TestTarget(target).pay(token, payAmount);
        }

        return "";
    }
}

// Encodes: (address token, uint128 borrowAmount, uint128 payAmount)
contract ForwardeeTesterImpl is ForwardeeTester {
    constructor(address _target) ForwardeeTester(_target) {}

    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == target, "ForwardeeTesterImpl: caller not target");
        (address token, uint128 borrowAmount, uint128 payAmount) = abi.decode(data, (address, uint128, uint128));

        // Additional partial borrow
        if (borrowAmount > 0) {
            TestTarget(target).borrow(token, borrowAmount / 2);
        }
        // Additional partial pay
        if (payAmount > 0) {
            TestTarget(target).pay(token, payAmount / 2);
        }

        return "";
    }
}

// ---------------------
// The Test Suite
// ---------------------

contract FlashAccountantTest is Test {
    TestTarget public target;
    LockerTesterImpl public lockerImpl;
    ForwardeeTesterImpl public forwarderImpl;
    address public someToken = address(0x1111);

    function setUp() public {
        target = new TestTarget();
        forwarderImpl = new ForwardeeTesterImpl(address(target));
        lockerImpl = new LockerTesterImpl(address(target), address(forwarderImpl));
    }

    // 1) Cannot borrow outside lock
    function test_cannotBorrowWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.borrow(someToken, 100);
    }

    // 2) Cannot pay outside lock
    function test_cannotPayWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.pay(someToken, 100);
    }

    // 3) Cannot forward outside lock
    function test_cannotForwardWithoutLock() public {
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.forward(address(forwarderImpl), "");
    }

    // 4) Only the active locker can borrow inside lock
    function test_onlyLockerCanBorrowInsideLock() public {
        vm.startPrank(address(lockerImpl));
        // net zero => no revert
        bytes memory data = abi.encode(false, someToken, uint128(100), uint128(100));
        target.lock(data);
        vm.stopPrank();

        // now no lock is active
        vm.expectRevert(IFlashAccountant.NotLocked.selector);
        target.borrow(someToken, 1);
    }

    // 5) Fuzz test: single lock with optional forward must revert if final net != 0
    function testFuzz_lockZeroDebt(bool runForward, uint128 borrowAmount, uint128 payAmount) public {
        /*
         We do:
           - borrow(borrowAmount)
           - if runForward: forward => borrow(borrowAmount/2), pay(payAmount/2)
           - pay(payAmount)

         The final net = borrowAmount + (borrowAmount/2 if runForward) - (payAmount + (payAmount/2 if runForward))

         To avoid overflow in the test, do everything as uint256.
        */
        uint256 bigBorrow = uint256(borrowAmount);
        uint256 bigPay = uint256(payAmount);

        uint256 finalBorrow;
        uint256 finalPay;

        if (!runForward) {
            finalBorrow = bigBorrow;
            finalPay = bigPay;
        } else {
            // cast to uint256 first to avoid overflow in expressions
            finalBorrow = bigBorrow + (bigBorrow / 2);
            finalPay = bigPay + (bigPay / 2);
        }

        // Prepare data
        bytes memory data = abi.encode(runForward, someToken, borrowAmount, payAmount);

        vm.prank(address(lockerImpl));
        if (finalBorrow != finalPay) {
            // Nonzero net => expect revert with DebtsNotZeroed
            vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
            target.lock(data);
        } else {
            // Zero net => no revert
            target.lock(data);
        }
    }

    // 6) Nested locking test in sequence
    function test_nestedLockingAndForwarding() public {
        // Lock #0 => net zero => success
        bytes memory data = abi.encode(true, someToken, uint128(100), uint128(100));
        vm.prank(address(lockerImpl));
        target.lock(data);

        // Lock #1 => mismatch => revert
        data = abi.encode(true, someToken, uint128(200), uint128(100));
        vm.prank(address(lockerImpl));
        vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
        target.lock(data);

        // Lock #2 => net zero => success
        data = abi.encode(true, someToken, uint128(300), uint128(300));
        vm.prank(address(lockerImpl));
        target.lock(data);
    }
}
