// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {TestToken} from "./TestToken.sol";
import {ILocker} from "../src/interfaces/IFlashAccountant.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

contract DebugWithdrawTest is Test, ILocker {
    using FlashAccountantLib for *;

    Core core;
    TestToken token0;
    address recipient = address(0x1234);

    string private currentAction;

    function setUp() public {
        core = new Core();
        token0 = new TestToken(address(core));
    }

    function testTokenBalance() public {
        // Check that core has tokens
        uint256 balance = token0.balanceOf(address(core));
        console.log("Core token balance:", balance);
        assertGt(balance, 0);
    }

    function testDirectWithdrawMultiple() public {
        uint128 amount = 100e18;

        // Check initial balances
        console.log("Initial core balance:", token0.balanceOf(address(core)));
        console.log("Initial recipient balance:", token0.balanceOf(recipient));

        // Test direct call to withdrawMultiple
        core.lock();

        console.log("Final core balance:", token0.balanceOf(address(core)));
        console.log("Final recipient balance:", token0.balanceOf(recipient));
    }

    function testTwoWithdraws() public {
        // Test calling withdraw twice to see if that works
        currentAction = "twoWithdraws";
        core.lock();
    }

    function locked(uint256) external {
        uint128 amount = 100e18;

        if (keccak256(bytes(currentAction)) == keccak256("twoWithdraws")) {
            // Test calling withdraw twice and then paying back the debt using core.pay
            console.log("Testing two separate withdraw calls");
            core.withdraw(address(token0), recipient, amount);
            console.log("After first withdraw - recipient balance:", token0.balanceOf(recipient));
            core.withdraw(address(token0), recipient, amount);
            console.log("After second withdraw - recipient balance:", token0.balanceOf(recipient));

            // Now pay back the debt using core.pay
            // First transfer tokens to this contract so we can pay
            vm.prank(recipient);
            token0.transfer(address(this), 200e18);

            // Then pay the debt
            core.pay(address(token0), 200e18);
            console.log("Paid back debt using core.pay");
            return;
        }

        // Test the existing withdraw function first
        console.log("Testing existing withdraw function");
        core.withdraw(address(token0), recipient, amount);
        console.log("After existing withdraw - recipient balance:", token0.balanceOf(recipient));

        // Reset for next test - mint more tokens to core instead of transferring back
        if (token0.balanceOf(recipient) > 0) {
            console.log("Recipient has tokens, continuing with withdrawMultiple test");
        }

        // Now test withdrawMultiple
        console.log("Testing withdrawMultiple");
        bytes memory callData = abi.encodePacked(
            core.withdrawMultiple.selector,
            token0, // token (20 bytes)
            recipient, // recipient (20 bytes)
            amount // amount (16 bytes)
        );

        console.log("Calldata length:", callData.length);
        console.logBytes(callData);

        (bool success, bytes memory returnData) = address(core).call(callData);
        if (!success) {
            console.log("Call failed");
            console.logBytes(returnData);
        }
        require(success, "withdrawMultiple failed");

        console.log("After withdrawMultiple - recipient balance:", token0.balanceOf(recipient));

        // Pay back the debt created by withdrawMultiple
        vm.prank(recipient);
        token0.transfer(address(this), amount);
        core.pay(address(token0), amount);
        console.log("Paid back withdrawMultiple debt");

        // Also pay back the debt from the first withdraw call
        vm.prank(recipient);
        token0.transfer(address(this), amount);
        core.pay(address(token0), amount);
        console.log("Paid back first withdraw debt");
    }
}
