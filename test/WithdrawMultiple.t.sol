// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

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

    function locked(uint256) external {
        if (keccak256(bytes(currentAction)) == keccak256("withdrawSingle")) {
            (address token, address to, uint128 amount) = abi.decode(currentData, (address, address, uint128));

            // Store initial balance to verify the withdrawal
            uint256 initialBalance = TestToken(token).balanceOf(to);

            ICore(core).withdrawSingle(token, to, amount);

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

            // Call withdrawMultiple directly with packed calldata
            bytes memory callData =
                abi.encodePacked(core.withdrawMultiple.selector, token0_, to0, amount0, token1_, to1, amount1);

            (bool success,) = address(core).call(callData);
            require(success, "withdrawMultiple failed");

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
        }
    }
}
