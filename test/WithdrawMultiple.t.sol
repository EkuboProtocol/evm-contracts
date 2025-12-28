// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TestToken} from "./TestToken.sol";
import {ILocker} from "../src/interfaces/IFlashAccountant.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

contract WithdrawMultipleTest is Test, ILocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    Core core;
    TestToken token0;
    TestToken token1;
    address recipient = address(0x1234);

    string private currentAction;
    bytes private currentData;

    function setUp() public {
        core = new Core();
        token0 = new TestToken(address(core));
        token1 = new TestToken(address(core));

        // Give core some ETH for native token withdrawals
        vm.deal(address(core), 10 ether);
    }

    function testWithdrawSingle() public {
        uint128 amount = 100e18;

        // Test single token withdrawal using CoreLib
        currentAction = "withdrawSingle";
        currentData = abi.encode(address(token0), recipient, amount);

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function testWithdrawTwo() public {
        uint128 amount0 = 100e18;
        uint128 amount1 = 200e18;

        // Test two token withdrawal using CoreLib
        currentAction = "withdrawTwo";
        currentData = abi.encode(address(token0), address(token1), recipient, amount0, amount1);

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function testWithdrawMultipleDirectly() public {
        uint128 amount0 = 50e18;
        uint128 amount1 = 75e18;

        // Test direct withdrawMultiple call
        currentAction = "withdrawMultipleDirect";
        currentData = abi.encode(address(token0), recipient, amount0, address(token1), recipient, amount1);

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function testWithdrawSameTokenMultipleTimes() public {
        uint128 amount1 = 30e18;
        uint128 amount2 = 20e18;
        address recipient2 = address(0x5678);

        // Test withdrawing the same token multiple times to different recipients
        currentAction = "withdrawSameTokenMultiple";
        currentData = abi.encode(address(token0), recipient, amount1, address(token0), recipient2, amount2);

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function testWithdrawSameTokenSameRecipientMultipleTimes() public {
        uint128 amount1 = 25e18;
        uint128 amount2 = 35e18;

        // Test withdrawing the same token multiple times to the same recipient
        currentAction = "withdrawSameTokenSameRecipient";
        currentData = abi.encode(address(token0), recipient, amount1, address(token0), recipient, amount2);

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function testWithdrawMixedTokensWithDuplicates() public {
        uint128 amount1 = 10e18;
        uint128 amount2 = 15e18;
        uint128 amount3 = 20e18;
        address recipient2 = address(0x9abc);

        // Test mixed scenario: token0 twice, token1 once
        currentAction = "withdrawMixedWithDuplicates";
        currentData = abi.encode(
            address(token0),
            recipient,
            amount1,
            address(token1),
            recipient2,
            amount2,
            address(token0),
            recipient2,
            amount3
        );

        core.lock();

        // The locked function handles verification and debt settlement
        // If we reach here, the test passed
    }

    function locked_6416899205(uint256) external {
        if (keccak256(bytes(currentAction)) == keccak256("withdrawSingle")) {
            (address token, address to, uint128 amount) = abi.decode(currentData, (address, address, uint128));

            // Store initial balance to verify the withdrawal
            uint256 initialBalance = TestToken(token).balanceOf(to);

            core.withdraw(token, to, amount);

            // Verify the withdrawal worked
            uint256 finalBalance = TestToken(token).balanceOf(to);
            require(finalBalance == initialBalance + amount, "Withdrawal failed");

            // Pay back the debt to settle the flash loan
            vm.prank(to);
            TestToken(token).transfer(address(this), amount);
            core.pay(token, amount);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawTwo")) {
            (address token0_, address token1_, address to, uint128 amount0, uint128 amount1) =
                abi.decode(currentData, (address, address, address, uint128, uint128));

            // Store initial balances
            uint256 initialBalance0 = TestToken(token0_).balanceOf(to);
            uint256 initialBalance1 = TestToken(token1_).balanceOf(to);

            ICore(core).withdrawTwo(token0_, token1_, to, amount0, amount1);

            // Verify the withdrawals worked
            uint256 finalBalance0 = TestToken(token0_).balanceOf(to);
            uint256 finalBalance1 = TestToken(token1_).balanceOf(to);
            require(finalBalance0 == initialBalance0 + amount0, "Token0 withdrawal failed");
            require(finalBalance1 == initialBalance1 + amount1, "Token1 withdrawal failed");

            // Pay back the debts
            vm.prank(to);
            TestToken(token0_).transfer(address(this), amount0);
            core.pay(token0_, amount0);

            vm.prank(to);
            TestToken(token1_).transfer(address(this), amount1);
            core.pay(token1_, amount1);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawMultipleDirect")) {
            // Manually construct the calldata for withdrawMultiple
            (address token0_, address to0, uint128 amount0, address token1_, address to1, uint128 amount1) =
                abi.decode(currentData, (address, address, uint128, address, address, uint128));

            // Store initial balances
            uint256 initialBalance0 = TestToken(token0_).balanceOf(to0);
            uint256 initialBalance1 = TestToken(token1_).balanceOf(to1);

            // Call withdraw directly with packed calldata
            bytes memory callData = abi.encodePacked(bytes4(0x3ccfd60b), token0_, to0, amount0, token1_, to1, amount1);

            (bool success,) = address(core).call(callData);
            require(success, "withdraw failed");

            // Verify the withdrawals worked
            uint256 finalBalance0 = TestToken(token0_).balanceOf(to0);
            uint256 finalBalance1 = TestToken(token1_).balanceOf(to1);
            require(finalBalance0 == initialBalance0 + amount0, "Token0 withdrawal failed");
            require(finalBalance1 == initialBalance1 + amount1, "Token1 withdrawal failed");

            // Pay back the debts
            vm.prank(to0);
            TestToken(token0_).transfer(address(this), amount0);
            core.pay(token0_, amount0);

            vm.prank(to1);
            TestToken(token1_).transfer(address(this), amount1);
            core.pay(token1_, amount1);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawSameTokenMultiple")) {
            // Test same token to different recipients
            (address token_, address to1, uint128 amount1, address token2_, address to2, uint128 amount2) =
                abi.decode(currentData, (address, address, uint128, address, address, uint128));

            require(token_ == token2_, "Expected same token");

            // Store initial balances
            uint256 initialBalance1 = TestToken(token_).balanceOf(to1);
            uint256 initialBalance2 = TestToken(token_).balanceOf(to2);

            // Call withdraw directly with packed calldata for same token multiple times
            bytes memory callData = abi.encodePacked(bytes4(0x3ccfd60b), token_, to1, amount1, token_, to2, amount2);

            (bool success,) = address(core).call(callData);
            require(success, "withdraw failed");

            // Verify the withdrawals worked
            uint256 finalBalance1 = TestToken(token_).balanceOf(to1);
            uint256 finalBalance2 = TestToken(token_).balanceOf(to2);
            require(finalBalance1 == initialBalance1 + amount1, "First withdrawal failed");
            require(finalBalance2 == initialBalance2 + amount2, "Second withdrawal failed");

            // Pay back the total debt (should be amount1 + amount2 for the single token)
            // Each recipient pays back what they received
            vm.prank(to1);
            TestToken(token_).transfer(address(this), amount1);
            vm.prank(to2);
            TestToken(token_).transfer(address(this), amount2);

            uint128 totalAmount = amount1 + amount2;
            core.pay(token_, totalAmount);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawSameTokenSameRecipient")) {
            // Test same token to same recipient multiple times
            (address token_, address to, uint128 amount1, address token2_, address to2, uint128 amount2) =
                abi.decode(currentData, (address, address, uint128, address, address, uint128));

            require(token_ == token2_ && to == to2, "Expected same token and recipient");

            // Store initial balance
            uint256 initialBalance = TestToken(token_).balanceOf(to);

            // Call withdraw directly with packed calldata for same token and recipient multiple times
            bytes memory callData = abi.encodePacked(bytes4(0x3ccfd60b), token_, to, amount1, token_, to, amount2);

            (bool success,) = address(core).call(callData);
            require(success, "withdraw failed");

            // Verify the withdrawal worked (should receive both amounts)
            uint256 finalBalance = TestToken(token_).balanceOf(to);
            require(finalBalance == initialBalance + amount1 + amount2, "Combined withdrawal failed");

            // Pay back the total debt
            uint128 totalAmount = amount1 + amount2;
            vm.prank(to);
            TestToken(token_).transfer(address(this), totalAmount);
            core.pay(token_, totalAmount);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawMixedWithDuplicates")) {
            // Test mixed scenario: token0 twice, token1 once
            (
                address token0_,
                address to1,
                uint128 amount1,
                address token1_,
                address to2,
                uint128 amount2,
                address token0_2,
                address to3,
                uint128 amount3
            ) = abi.decode(
                currentData, (address, address, uint128, address, address, uint128, address, address, uint128)
            );

            require(token0_ == token0_2, "Expected same token for first and third withdrawal");

            // Store initial balances
            uint256 initialBalance1 = TestToken(token0_).balanceOf(to1);
            uint256 initialBalance2 = TestToken(token1_).balanceOf(to2);
            uint256 initialBalance3 = TestToken(token0_).balanceOf(to3);

            // Call withdraw directly with packed calldata: token0, token1, token0
            bytes memory callData = abi.encodePacked(
                bytes4(0x3ccfd60b), token0_, to1, amount1, token1_, to2, amount2, token0_, to3, amount3
            );

            (bool success,) = address(core).call(callData);
            require(success, "withdraw failed");

            // Verify the withdrawals worked
            uint256 finalBalance1 = TestToken(token0_).balanceOf(to1);
            uint256 finalBalance2 = TestToken(token1_).balanceOf(to2);
            uint256 finalBalance3 = TestToken(token0_).balanceOf(to3);
            require(finalBalance1 == initialBalance1 + amount1, "First token0 withdrawal failed");
            require(finalBalance2 == initialBalance2 + amount2, "Token1 withdrawal failed");
            require(finalBalance3 == initialBalance3 + amount3, "Second token0 withdrawal failed");

            // Pay back the debts
            // Each recipient pays back what they received
            vm.prank(to1);
            TestToken(token0_).transfer(address(this), amount1);
            vm.prank(to3);
            TestToken(token0_).transfer(address(this), amount3);

            uint128 totalToken0Amount = amount1 + amount3;
            core.pay(token0_, totalToken0Amount);

            vm.prank(to2);
            TestToken(token1_).transfer(address(this), amount2);
            core.pay(token1_, amount2);
        }
    }
}
