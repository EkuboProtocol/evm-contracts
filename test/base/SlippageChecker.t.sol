// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {SlippageChecker} from "../../src/base/SlippageChecker.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/interfaces/ICore.sol";
import {TestToken} from "../TestToken.sol";

contract TestTarget is SlippageChecker {}

contract SlippageCheckerTest is Test {
    TestToken token;
    TestTarget target;

    function setUp() public {
        token = new TestToken(address(this));
        target = new TestTarget();
    }

    function test_checkDeadline(uint256 time, uint256 deadline) public {
        vm.warp(time);
        if (time > deadline) {
            vm.expectRevert(abi.encodeWithSelector(SlippageChecker.TransactionExpired.selector, deadline));
        }
        target.checkDeadline(deadline);
    }

    function test_allFunctionsPayable() public {
        target.checkDeadline{value: 1}(type(uint256).max);
        target.recordBalanceForSlippageCheck{value: 1}(NATIVE_TOKEN_ADDRESS);
        target.checkMaximumInputNotExceeded{value: 1}(NATIVE_TOKEN_ADDRESS, type(uint256).max);
        vm.deal(address(this), address(this).balance + 2);
        target.checkMinimumOutputReceived{value: 1}(NATIVE_TOKEN_ADDRESS, 0);
    }

    function test_checkMinimumOutputReceived(uint256 actualOutput, uint256 minimumOutput, bool isETH) public {
        address tokenAddress = isETH ? NATIVE_TOKEN_ADDRESS : address(token);
        address recipient = payable(address(0xdeadbeefdeadbeef));

        vm.prank(recipient);
        target.recordBalanceForSlippageCheck(tokenAddress);

        if (actualOutput > 0) {
            if (isETH) {
                vm.deal(recipient, actualOutput);
            } else {
                token.transfer(recipient, actualOutput);
            }
        }

        if (actualOutput < minimumOutput) {
            vm.expectRevert(
                abi.encodeWithSelector(SlippageChecker.MinimumOutputNotReceived.selector, tokenAddress, minimumOutput)
            );
        }
        vm.prank(recipient);
        target.checkMinimumOutputReceived(tokenAddress, minimumOutput);
    }

    function test_checkMaximumInputNotExceeded(
        uint256 startingBalance,
        uint256 actualInput,
        uint256 maximumInput,
        bool isETH
    ) public {
        address tokenAddress = isETH ? NATIVE_TOKEN_ADDRESS : address(token);
        address spender = payable(address(0xdeadbeefdeadbeef));

        startingBalance = bound(startingBalance, actualInput, type(uint256).max);

        if (startingBalance > 0) {
            if (isETH) {
                vm.deal(spender, startingBalance);
            } else {
                token.transfer(spender, startingBalance);
            }
        }

        vm.prank(spender);
        target.recordBalanceForSlippageCheck(tokenAddress);

        if (actualInput > 0) {
            if (isETH) {
                vm.deal(spender, startingBalance - actualInput);
            } else {
                vm.prank(spender);
                token.transfer(address(0), actualInput);
            }
        }

        if (actualInput > maximumInput) {
            vm.expectRevert(
                abi.encodeWithSelector(SlippageChecker.MaximumInputExceeded.selector, tokenAddress, maximumInput)
            );
        }
        vm.prank(spender);
        target.checkMaximumInputNotExceeded(tokenAddress, maximumInput);
    }
}
