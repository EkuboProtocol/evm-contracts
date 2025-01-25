// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ILocker, IForwardee, IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";

// ---------------------------------------
// Base TestTarget as before
// ---------------------------------------
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

// ---------------------------------------
// A "multi-level" locker that can re-enter .lock()
// ---------------------------------------
contract NestedLocker is ILocker {
    address public immutable target;
    address public immutable token;

    // We'll store recursion depth (how many times we plan to nest),
    // as well as arrays of amounts or booleans that define each step.
    // This is just to illustrate the concept.
    // In practice you might store them differently or pass them around in `data`.
    struct NestParams {
        uint8 maxDepth; // how deep we can go
        uint128 borrowAmount; // how much we borrow at this level
        uint128 payAmount; // how much we pay at this level
        bool doForward; // if we also forward at this level
    }

    // Forwardee we might forward to
    address public forwardee;

    constructor(address _target, address _forwardee, address _token) {
        target = _target;
        forwardee = _forwardee;
        token = _token;
    }

    // data will encode (NestParams params, uint8 currentDepth)
    function locked(uint256, /*id*/ bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == target, "NestedLocker: caller not target");

        (NestParams memory params, uint8 currentDepth) = abi.decode(data, (NestParams, uint8));

        // 1) borrow
        TestTarget(target).borrow(token, params.borrowAmount);

        // 2) optionally forward
        if (params.doForward) {
            IFlashAccountant(target).forward(forwardee, "");
        }

        // 3) nest deeper if we haven't exceeded maxDepth
        if (currentDepth < params.maxDepth) {
            // prepare data for next recursion
            // maybe we randomize new borrow/pay, or reuse the same, or vary them in an array
            // here we just increment depth to illustrate
            NestParams memory nextParams = params; // same borrow/pay/forward
            uint8 nextDepth = currentDepth + 1;

            bytes memory nextData = abi.encode(nextParams, nextDepth);
            IFlashAccountant(target).lock(nextData);
        }

        // 4) pay
        if (params.payAmount > 0) {
            TestTarget(target).pay(token, params.payAmount);
        }

        return "";
    }
}

// ---------------------------------------
// A minimal forwardee for demonstration
// ---------------------------------------
contract SimpleForwardee is IForwardee {
    address public immutable target;

    constructor(address _target) {
        target = _target;
    }

    function forwarded(address, /*locker*/ uint256, /*id*/ bytes calldata /*data*/ )
        external
        view
        override
        returns (bytes memory)
    {
        // For demonstration, do some small random actions here if you want
        // Here, let's do nothing or a trivial forward call
        require(msg.sender == target, "SimpleForwardee: caller not target");
        return "";
    }
}

// ---------------------------------------
// The actual test
// ---------------------------------------
contract FlashAccountantMultiLevelTest is Test {
    TestTarget public target;
    NestedLocker public nestedLocker;
    SimpleForwardee public forwardee;
    address public someToken = address(0xABCD);

    function setUp() public {
        target = new TestTarget();
        forwardee = new SimpleForwardee(address(target));
        nestedLocker = new NestedLocker(address(target), address(forwardee), someToken);
    }

    // Fuzz test that tries random nesting
    // We'll pick random borrow/pay each level, up to maxDepth
    function testFuzz_nestedLocking(uint8 maxDepth, uint128 borrowAmount, uint128 payAmount, bool doForward) public {
        // We'll avoid extremely large maxDepth; let's clamp it to something modest.
        if (maxDepth > 5) maxDepth = 5;

        // If borrowAmount < payAmount => we can still nest, but final debt might be negative
        // which we'll see as we do each level. If final net != 0 => revert.
        // We'll allow the normal flash accountant logic to revert if the net is non-zero.

        // Build the data
        NestedLocker.NestParams memory params = NestedLocker.NestParams({
            maxDepth: maxDepth,
            borrowAmount: borrowAmount,
            payAmount: payAmount,
            doForward: doForward
        });

        bytes memory data = abi.encode(params, uint8(0)); // start at depth = 0

        // Start the lock from nestedLocker
        vm.prank(address(nestedLocker));

        // If net debt ends up zero, no revert; else revert
        // The net is effectively (borrow - pay) * (maxDepth+1)
        // plus any partial forward manipulations if doForward in that forwardee.
        // Our forwardee is trivial, but you could add more borrow/pays there if you like.
        uint256 finalBorrow = (uint256(borrowAmount) * (maxDepth + 1));
        uint256 finalPay = (uint256(payAmount) * (maxDepth + 1));

        if (finalBorrow != finalPay) {
            vm.expectRevert(IFlashAccountant.DebtsNotZeroed.selector);
            target.lock(data);
        } else {
            target.lock(data);
        }
    }
}
