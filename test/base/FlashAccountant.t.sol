// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ILocker, IForwardee, IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";

// --------------------------------------------------
//                 Base Testing Target
// --------------------------------------------------

/**
 * @notice A simple contract that extends FlashAccountant and exposes
 * `borrow` / `pay` to manipulate debt within the current lock context.
 */
contract TestTarget is FlashAccountant {
    function borrow(address token, uint128 amount) external {
        // reverts if not currently locked
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

// --------------------------------------------------
//     Single-Level Locker & Forwarder Test Setup
// --------------------------------------------------

/**
 * @dev LockerTester base that does nothing by default, just to silence warnings.
 */
abstract contract LockerTester is ILocker {
    address public target;
    address public forwardee;

    constructor(address _target, address _forwardee) {
        target = _target;
        forwardee = _forwardee;
    }

    // Unused parameters => name them with underscores or remove them
    function locked(uint256, /*id*/ bytes calldata /*data*/ ) external virtual override returns (bytes memory) {
        return bytes("");
    }
}

/**
 * @dev ForwardeeTester base that does nothing by default, just to silence warnings.
 */
abstract contract ForwardeeTester is IForwardee {
    address public target;

    constructor(address _target) {
        target = _target;
    }

    // Unused parameters => name them with underscores or remove them
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
 * @notice LockerTesterImpl: performs a borrow, an optional forward,
 * and then a pay in the locked(...) callback. Data encodes:
 *   (bool runForward, address token, uint128 borrowAmount, uint128 payAmount)
 */
contract LockerTesterImpl is LockerTester {
    constructor(address _target, address _forwardee) LockerTester(_target, _forwardee) {}

    function locked(uint256, /*id*/ bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == target);

        (bool runForward, address token, uint128 borrowAmount, uint128 payAmount) =
            abi.decode(data, (bool, address, uint128, uint128));

        // Borrow
        TestTarget(target).borrow(token, borrowAmount);

        // Optionally forward
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

/**
 * @notice ForwardeeTesterImpl: in the forwarded(...) callback, does a partial borrow/pay.
 * Data encodes: (address token, uint128 borrowAmount, uint128 payAmount)
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

        // extra partial borrow
        if (borrowAmount > 0) {
            TestTarget(target).borrow(token, borrowAmount / 2);
        }
        // extra partial pay
        if (payAmount > 0) {
            TestTarget(target).pay(token, payAmount / 2);
        }

        return "";
    }
}

// --------------------------------------------------
// Single-Level Usage Test Suite (no recursion)
// --------------------------------------------------

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

    // 5) Single-level fuzz test: if final net debt != 0, revert with DebtsNotZeroed
    function testFuzz_lockZeroDebt(bool runForward, uint128 borrowAmount, uint128 payAmount) public {
        /*
         Borrow: borrowAmount
         Optional forward => partial borrow/partial pay:
           (borrowAmount/2, payAmount/2)
         Pay: payAmount
         
         final net = borrowAmount + (runForward ? borrowAmount/2 : 0)
                   - [payAmount + (runForward ? payAmount/2 : 0)]

         We do all arithmetic in uint256 to avoid 128 overflow.
        */
        uint256 b = borrowAmount;
        uint256 p = payAmount;

        uint256 finalBorrow;
        uint256 finalPay;

        if (!runForward) {
            finalBorrow = b;
            finalPay = p;
        } else {
            finalBorrow = b + (b / 2);
            finalPay = p + (p / 2);
        }

        bytes memory data = abi.encode(runForward, someToken, borrowAmount, payAmount);

        vm.prank(address(lockerImpl));
        if (finalBorrow != finalPay) {
            vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
            target.lock(data);
        } else {
            target.lock(data);
        }
    }

    // 6) Nested locking in the sense of multiple consecutive locks (but not recursion).
    function test_nestedLockingAndForwarding() public {
        // #0 => net zero => success
        bytes memory data = abi.encode(true, someToken, uint128(100), uint128(100));
        vm.prank(address(lockerImpl));
        target.lock(data);

        // #1 => mismatch => revert
        data = abi.encode(true, someToken, uint128(200), uint128(100));
        vm.prank(address(lockerImpl));
        vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
        target.lock(data);

        // #2 => net zero => success
        data = abi.encode(true, someToken, uint128(300), uint128(300));
        vm.prank(address(lockerImpl));
        target.lock(data);
    }
}

// --------------------------------------------------
//    Multi-Level (Recursive) Locking Test Setup
// --------------------------------------------------

/**
 * @notice A nested locker that, inside its `locked` callback, can call
 * `lock(...)` again for deeper levels. This demonstrates recursion with
 * multiple lock IDs in a single outer call stack.
 */
contract NestedLocker is ILocker {
    address public target;
    address public token;
    address public forwardee;

    struct NestParams {
        uint8 maxDepth; // how many times we can nest
        uint128 borrowAmount; // how much to borrow at each level
        uint128 payAmount; // how much to pay at each level
        bool doForward; // if we also forward at each level
    }

    constructor(address _target, address _forwardee, address _token) {
        target = _target;
        forwardee = _forwardee;
        token = _token;
    }

    /**
     * @dev Data encodes (NestParams params, uint8 currentDepth).
     */
    function locked(uint256, /*id*/ bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == target);

        (NestParams memory params, uint8 currentDepth) = abi.decode(data, (NestParams, uint8));

        // Borrow at this level
        TestTarget(target).borrow(token, params.borrowAmount);

        // Optionally forward
        if (params.doForward) {
            IFlashAccountant(target).forward(forwardee, "");
        }

        // If we can still go deeper, call lock(...) again
        if (currentDepth < params.maxDepth) {
            NestParams memory nextParams = params; // same settings
            uint8 nextDepth = currentDepth + 1;

            bytes memory nextData = abi.encode(nextParams, nextDepth);
            IFlashAccountant(target).lock(nextData);
        }

        // Pay at this level
        if (params.payAmount > 0) {
            TestTarget(target).pay(token, params.payAmount);
        }

        return "";
    }
}

/**
 * @notice A simple forwardee that doesn't do further borrowing/paying
 * (or you could expand to do partial manipulations if you want).
 */
contract SimpleForwardee is IForwardee {
    address public target;

    constructor(address _target) {
        target = _target;
    }

    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata /*data*/ )
        external
        view
        override
        returns (bytes memory)
    {
        require(msg.sender == target);
        // No extra borrow/pay here, but you could add it to stress test further.
        return "";
    }
}

// --------------------------------------------------
// Recursive (Deep) Locking Test Suite
// --------------------------------------------------

contract FlashAccountantNestedLockTest is Test {
    TestTarget public target;
    NestedLocker public nestedLocker;
    SimpleForwardee public forwardee;

    // We'll use a different token for clarity, but it's arbitrary
    address public someToken = address(0xABCD);

    function setUp() public {
        target = new TestTarget();
        forwardee = new SimpleForwardee(address(target));
        nestedLocker = new NestedLocker(address(target), address(forwardee), someToken);
    }

    /**
     * @notice Fuzz test: recursively lock up to `maxDepth` times, each time
     * borrow/pay the same amounts. If the final net is not zero, revert.
     *
     * We'll interpret final net as (borrow - pay) * (maxDepth+1), ignoring
     * forward overhead here (since our forwardee is a no-op).
     */
    function testFuzz_nestedLocking(uint8 maxDepth, uint128 borrowAmount, uint128 payAmount, bool doForward) public {
        // clamp maxDepth to keep recursion feasible
        if (maxDepth > 5) {
            maxDepth = 5;
        }

        // We'll rely on the final net debt check from FlashAccountant
        // If net != 0, revert with DebtsNotZeroed.

        // Prepare the data
        NestedLocker.NestParams memory params = NestedLocker.NestParams({
            maxDepth: maxDepth,
            borrowAmount: borrowAmount,
            payAmount: payAmount,
            doForward: doForward
        });

        bytes memory data = abi.encode(params, uint8(0));

        // Start the lock from nestedLocker
        vm.prank(address(nestedLocker));

        // If finalBorrow != finalPay => revert, else no revert
        uint256 finalBorrow = uint256(borrowAmount) * (maxDepth + 1);
        uint256 finalPay = uint256(payAmount) * (maxDepth + 1);

        if (finalBorrow != finalPay) {
            vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
            target.lock(data);
        } else {
            target.lock(data);
        }
    }

    /**
     * @notice A deterministic test for deeper nesting (no fuzz), ensuring
     * we can nest multiple times and come out with zero or non-zero net debt.
     */
    function test_nestedLockFixedDepth() public {
        // We'll do a 3-level nest
        //   Depth 0 => borrow 100, pay 100
        //   Depth 1 => borrow 100, pay 100
        //   Depth 2 => borrow 100, pay 100
        // Net = 0 => success

        NestedLocker.NestParams memory params =
            NestedLocker.NestParams({maxDepth: 2, borrowAmount: 100, payAmount: 100, doForward: false});

        bytes memory data = abi.encode(params, uint8(0));
        vm.prank(address(nestedLocker));
        target.lock(data);
    }
}
