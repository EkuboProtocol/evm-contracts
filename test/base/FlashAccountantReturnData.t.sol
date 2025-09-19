// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {FullTest} from "../FullTest.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {TestToken} from "../TestToken.sol";

/// @title FlashAccountantReturnDataTest
/// @notice Tests for verifying the return data formats of startPayments and completePayments
contract FlashAccountantReturnDataTest is FullTest {
    TestLocker public testLocker;

    function setUp() public override {
        super.setUp();
        testLocker = new TestLocker(IFlashAccountant(payable(address(core))));
    }

    /// @notice Test that startPayments returns the correct starting token balances
    function test_startPayments_returnsCorrectBalances() public {
        // Setup: Give the core contract some tokens
        uint256 token0Amount = 1000e18;
        uint256 token1Amount = 2000e18;

        token0.transfer(address(core), token0Amount);
        token1.transfer(address(core), token1Amount);

        // Test startPayments with two tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        bytes memory returnData = testLocker.testStartPayments(tokens);

        // The return data is raw bytes containing the balances (32 bytes each)
        assertEq(returnData.length, 64, "Should return 64 bytes for 2 tokens (32 bytes each)");

        uint256 balance0;
        uint256 balance1;
        assembly {
            balance0 := mload(add(returnData, 0x20))
            balance1 := mload(add(returnData, 0x40))
        }

        assertEq(balance0, token0Amount, "Token0 balance should match");
        assertEq(balance1, token1Amount, "Token1 balance should match");
    }

    /// @notice Test that startPayments returns zero balances when tokens have no balance
    function test_startPayments_returnsZeroBalances() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        bytes memory returnData = testLocker.testStartPayments(tokens);

        // The return data is raw bytes containing the balances (32 bytes each)
        assertEq(returnData.length, 64, "Should return 64 bytes for 2 tokens");

        uint256 balance0;
        uint256 balance1;
        assembly {
            balance0 := mload(add(returnData, 0x20))
            balance1 := mload(add(returnData, 0x40))
        }

        assertEq(balance0, 0, "Token0 balance should be zero");
        assertEq(balance1, 0, "Token1 balance should be zero");
    }

    /// @notice Test that completePayments returns the correct payment amounts in packed format
    function test_completePayments_returnsCorrectPaymentAmounts() public {
        // Setup: Give tokens to the test locker so it can make payments
        uint256 token0Payment = 500e18;
        uint256 token1Payment = 750e18;

        token0.transfer(address(testLocker), token0Payment);
        token1.transfer(address(testLocker), token1Payment);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        // Test the complete payment flow
        (bytes memory startData, bytes memory completeData) =
            testLocker.testStartAndCompletePayments(tokens, token0Payment, token1Payment);

        // Verify startPayments returned initial balances (should be 0 since core starts with no tokens)
        assertEq(startData.length, 64, "Should return 64 bytes for 2 tokens");

        uint256 initialBalance0;
        uint256 initialBalance1;
        assembly {
            initialBalance0 := mload(add(startData, 0x20))
            initialBalance1 := mload(add(startData, 0x40))
        }
        assertEq(initialBalance0, 0, "Initial token0 balance should be zero");
        assertEq(initialBalance1, 0, "Initial token1 balance should be zero");

        // Verify completePayments returned correct payment amounts
        // The return data should be packed uint128 values (16 bytes each)
        assertEq(completeData.length, 32, "Should return 32 bytes for 2 tokens (16 bytes each)");

        // Extract the packed uint128 values
        uint128 payment0;
        uint128 payment1;
        assembly {
            payment0 := shr(128, mload(add(completeData, 0x20)))
            payment1 := shr(128, mload(add(completeData, 0x30)))
        }

        assertEq(payment0, token0Payment, "Token0 payment amount should match");
        assertEq(payment1, token1Payment, "Token1 payment amount should match");
    }

    /// @notice Test that completePayments returns zero when no payments are made
    function test_completePayments_returnsZeroWhenNoPayments() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        (bytes memory startData, bytes memory completeData) = testLocker.testStartAndCompletePayments(tokens, 0, 0);

        // Verify startPayments returned zero balances
        assertEq(startData.length, 64, "Should return 64 bytes for 2 tokens");

        uint256 initialBalance0;
        uint256 initialBalance1;
        assembly {
            initialBalance0 := mload(add(startData, 0x20))
            initialBalance1 := mload(add(startData, 0x40))
        }
        assertEq(initialBalance0, 0, "Initial token0 balance should be zero");
        assertEq(initialBalance1, 0, "Initial token1 balance should be zero");

        // Verify completePayments returned zero payments
        assertEq(completeData.length, 32, "Should return 32 bytes for 2 tokens");

        uint128 payment0;
        uint128 payment1;
        assembly {
            payment0 := shr(128, mload(add(completeData, 0x20)))
            payment1 := shr(128, mload(add(completeData, 0x30)))
        }

        assertEq(payment0, 0, "Token0 payment should be zero");
        assertEq(payment1, 0, "Token1 payment should be zero");
    }

    /// @notice Test startPayments and completePayments with native token
    function test_startAndCompletePayments_withNativeToken() public {
        // Give the core contract some ETH
        uint256 ethAmount = 1 ether;
        vm.deal(address(core), ethAmount);

        // Give the test locker some ETH to make payments
        uint256 paymentAmount = 0.5 ether;
        vm.deal(address(testLocker), paymentAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = NATIVE_TOKEN_ADDRESS;

        (bytes memory startData, bytes memory completeData) =
            testLocker.testStartAndCompletePaymentsETH(tokens, paymentAmount);

        // Verify startPayments returned the initial ETH balance
        assertEq(startData.length, 32, "Should return 32 bytes for 1 token");

        uint256 initialBalance;
        assembly {
            initialBalance := mload(add(startData, 0x20))
        }
        assertEq(initialBalance, ethAmount, "Initial ETH balance should match");

        // Verify completePayments returned the correct payment amount
        assertEq(completeData.length, 16, "Should return 16 bytes for 1 token");

        uint128 payment;
        assembly {
            payment := shr(128, mload(add(completeData, 0x20)))
        }

        assertEq(payment, paymentAmount, "ETH payment amount should match");
    }

    /// @notice Test with single token to verify format consistency
    function test_singleToken_returnDataFormat() public {
        uint256 tokenAmount = 1000e18;
        token0.transfer(address(core), tokenAmount);
        token0.transfer(address(testLocker), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);

        (bytes memory startData, bytes memory completeData) = testLocker.testStartAndCompletePayments(tokens, 100e18, 0);

        // Verify startPayments format for single token
        assertEq(startData.length, 32, "Should return 32 bytes for 1 token");

        uint256 initialBalance;
        assembly {
            initialBalance := mload(add(startData, 0x20))
        }
        assertEq(initialBalance, tokenAmount, "Balance should match");

        // Verify completePayments format for single token
        assertEq(completeData.length, 16, "Should return 16 bytes for 1 token");

        uint128 payment;
        assembly {
            payment := shr(128, mload(add(completeData, 0x20)))
        }

        assertEq(payment, 100e18, "Payment amount should match");
    }
}

/// @title TestLocker
/// @notice A test contract that extends BaseLocker to test FlashAccountant return data
contract TestLocker is BaseLocker {
    constructor(IFlashAccountant accountant) BaseLocker(accountant) {}

    /// @notice Test startPayments and return the raw bytes
    function testStartPayments(address[] memory tokens) external returns (bytes memory) {
        return lock(abi.encode("startPayments", tokens));
    }

    /// @notice Test both startPayments and completePayments
    function testStartAndCompletePayments(address[] memory tokens, uint256 token0Amount, uint256 token1Amount)
        external
        returns (bytes memory startData, bytes memory completeData)
    {
        return abi.decode(lock(abi.encode("startAndComplete", tokens, token0Amount, token1Amount)), (bytes, bytes));
    }

    /// @notice Test both startPayments and completePayments with ETH
    function testStartAndCompletePaymentsETH(address[] memory tokens, uint256 ethAmount)
        external
        returns (bytes memory startData, bytes memory completeData)
    {
        return abi.decode(lock(abi.encode("startAndCompleteETH", tokens, ethAmount)), (bytes, bytes));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        string memory action = abi.decode(data, (string));

        if (keccak256(bytes(action)) == keccak256(bytes("startPayments"))) {
            (, address[] memory tokens) = abi.decode(data, (string, address[]));

            // Call startPayments and capture the return data
            bytes memory callData = abi.encodeWithSelector(IFlashAccountant.startPayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                callData = abi.encodePacked(callData, abi.encode(tokens[i]));
            }

            (bool success, bytes memory returnData) = address(ACCOUNTANT).call(callData);
            require(success, "startPayments failed");

            return returnData;
        } else if (keccak256(bytes(action)) == keccak256(bytes("startAndComplete"))) {
            (, address[] memory tokens, uint256 token0Amount, uint256 token1Amount) =
                abi.decode(data, (string, address[], uint256, uint256));

            // Call startPayments
            bytes memory startCallData = abi.encodeWithSelector(IFlashAccountant.startPayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                startCallData = abi.encodePacked(startCallData, abi.encode(tokens[i]));
            }

            (bool startSuccess, bytes memory startData) = address(ACCOUNTANT).call(startCallData);
            require(startSuccess, "startPayments failed");

            // Transfer tokens to the accountant
            if (tokens.length > 0 && token0Amount > 0) {
                TestToken(tokens[0]).transfer(address(ACCOUNTANT), token0Amount);
            }
            if (tokens.length > 1 && token1Amount > 0) {
                TestToken(tokens[1]).transfer(address(ACCOUNTANT), token1Amount);
            }

            // Call completePayments
            bytes memory completeCallData = abi.encodeWithSelector(IFlashAccountant.completePayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                completeCallData = abi.encodePacked(completeCallData, abi.encode(tokens[i]));
            }

            (bool completeSuccess, bytes memory completeData) = address(ACCOUNTANT).call(completeCallData);
            require(completeSuccess, "completePayments failed");

            // Balance the debt by withdrawing the exact amounts that were paid
            // Extract payment amounts from completeData to ensure exact matching
            for (uint256 i = 0; i < tokens.length; i++) {
                uint128 paymentAmount;
                assembly {
                    paymentAmount := shr(128, mload(add(completeData, add(0x20, mul(i, 16)))))
                }
                if (paymentAmount > 0) {
                    withdraw(tokens[i], paymentAmount, address(this));
                }
            }

            return abi.encode(startData, completeData);
        } else if (keccak256(bytes(action)) == keccak256(bytes("startAndCompleteETH"))) {
            (, address[] memory tokens, uint256 ethAmount) = abi.decode(data, (string, address[], uint256));

            // Call startPayments
            bytes memory startCallData = abi.encodeWithSelector(IFlashAccountant.startPayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                startCallData = abi.encodePacked(startCallData, abi.encode(tokens[i]));
            }

            (bool startSuccess, bytes memory startData) = address(ACCOUNTANT).call(startCallData);
            require(startSuccess, "startPayments failed");

            // Send ETH to the accountant
            if (ethAmount > 0) {
                (bool sent,) = address(ACCOUNTANT).call{value: ethAmount}("");
                require(sent, "ETH transfer failed");
            }

            // Call completePayments
            bytes memory completeCallData = abi.encodeWithSelector(IFlashAccountant.completePayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                completeCallData = abi.encodePacked(completeCallData, abi.encode(tokens[i]));
            }

            (bool completeSuccess, bytes memory completeData) = address(ACCOUNTANT).call(completeCallData);
            require(completeSuccess, "completePayments failed");

            // Balance the debt by withdrawing the exact amount that was paid
            // Extract payment amount from completeData to ensure exact matching
            uint128 paymentAmount;
            assembly {
                paymentAmount := shr(128, mload(add(completeData, 0x20)))
            }
            if (paymentAmount > 0) {
                withdraw(NATIVE_TOKEN_ADDRESS, paymentAmount, address(this));
            }

            return abi.encode(startData, completeData);
        }

        revert("Unknown action");
    }

    receive() external payable {}
}
