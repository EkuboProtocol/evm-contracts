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
    function test_startPayments_returnsCorrectBalances(uint128 token0Amount, uint128 token1Amount) public {
        // Bound amounts to reasonable values to avoid overflow and ensure we have enough tokens
        token0Amount = uint128(bound(token0Amount, 0, type(uint128).max / 2));
        token1Amount = uint128(bound(token1Amount, 0, type(uint128).max / 2));

        // Setup: Give the core contract some tokens
        if (token0Amount > 0) token0.transfer(address(core), token0Amount);
        if (token1Amount > 0) token1.transfer(address(core), token1Amount);

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
    function test_startPayments_returnsZeroBalances(uint8 rawTokenCount) public {
        // Bound token count to reasonable values (1-5 tokens) - more restrictive
        uint8 tokenCount = uint8(bound(rawTokenCount, 1, 5));

        // Additional safety checks
        require(tokenCount >= 1 && tokenCount <= 5, "Token count out of bounds");

        // Create array of test tokens
        address[] memory tokens = new address[](tokenCount);

        // Create new TestToken instances for better test coverage
        for (uint256 i = 0; i < tokenCount; i++) {
            if (i == 0) {
                tokens[i] = address(token0);
            } else if (i == 1) {
                tokens[i] = address(token1);
            } else {
                // Create new TestToken instances for additional tokens
                tokens[i] = address(new TestToken(address(0xdead)));
            }
        }

        bytes memory returnData = testLocker.testStartPayments(tokens);

        // The return data is raw bytes containing the balances (32 bytes each)
        uint256 expectedLength = uint256(tokenCount) * 32;
        require(expectedLength <= 160, "Expected length too large"); // 5 * 32 = 160
        assertEq(returnData.length, expectedLength, "Should return 32 bytes per token");

        // Verify all balances are zero
        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 tokenBalance;
            uint256 offset = 0x20 + (i * 32);
            require(offset <= returnData.length, "Offset out of bounds");
            assembly {
                tokenBalance := mload(add(returnData, offset))
            }
            assertEq(tokenBalance, 0, "Token balance should be zero");
        }
    }

    /// @notice Test that completePayments returns the correct payment amounts in packed format
    function test_completePayments_returnsCorrectPaymentAmounts(uint128 token0Payment, uint128 token1Payment) public {
        // Bound amounts to reasonable values to avoid overflow and ensure we have enough tokens
        token0Payment = uint128(bound(token0Payment, 0, type(uint128).max / 2));
        token1Payment = uint128(bound(token1Payment, 0, type(uint128).max / 2));

        // Setup: Give tokens to the test locker so it can make payments
        if (token0Payment > 0) token0.transfer(address(testLocker), token0Payment);
        if (token1Payment > 0) token1.transfer(address(testLocker), token1Payment);

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
    function test_completePayments_returnsZeroWhenNoPayments(uint8 tokenCount) public {
        // Bound token count to reasonable values (1-5 tokens for this zero-payment test)
        tokenCount = uint8(bound(tokenCount, 1, 5));

        // Create array of test tokens
        address[] memory tokens = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            if (i == 0) {
                tokens[i] = address(token0);
            } else if (i == 1) {
                tokens[i] = address(token1);
            } else {
                // Create new TestToken instances for additional tokens
                tokens[i] = address(new TestToken(address(0xdead)));
            }
        }

        // Create zero amounts array
        uint256[] memory zeroAmounts = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            zeroAmounts[i] = 0;
        }

        (bytes memory startData, bytes memory completeData) =
            testLocker.testStartAndCompletePaymentsMultiple(tokens, zeroAmounts);

        // Verify startPayments returned zero balances
        assertEq(startData.length, tokenCount * 32, "Should return 32 bytes per token");

        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 initialBalance;
            assembly {
                initialBalance := mload(add(startData, add(0x20, mul(i, 32))))
            }
            assertEq(initialBalance, 0, "Initial balance should be zero");
        }

        // Verify completePayments returned zero payments
        assertEq(completeData.length, tokenCount * 16, "Should return 16 bytes per token");

        for (uint256 i = 0; i < tokenCount; i++) {
            uint128 payment;
            assembly {
                payment := shr(128, mload(add(completeData, add(0x20, mul(i, 16)))))
            }
            assertEq(payment, 0, "Payment should be zero");
        }
    }

    /// @notice Test startPayments and completePayments return data format with native token address
    /// @dev Note: startPayments/completePayments don't actually support native ETH value tracking
    /// since they only call balanceOf(). This test verifies the format when using NATIVE_TOKEN_ADDRESS
    /// but expects zero values since balanceOf(address(0)) will fail and return 0.
    function test_startAndCompletePayments_withNativeToken_formatOnly() public {
        address[] memory tokens = new address[](1);
        tokens[0] = NATIVE_TOKEN_ADDRESS;

        (bytes memory startData, bytes memory completeData) = testLocker.testStartAndCompletePayments(tokens, 0, 0);

        // Verify startPayments returned correct format (but zero balance since balanceOf fails on address(0))
        assertEq(startData.length, 32, "Should return 32 bytes for 1 token");

        uint256 initialBalance;
        assembly {
            initialBalance := mload(add(startData, 0x20))
        }
        assertEq(initialBalance, 0, "Native token balance should be zero (balanceOf fails on address(0))");

        // Verify completePayments returned correct format (but zero payment)
        assertEq(completeData.length, 16, "Should return 16 bytes for 1 token");

        uint128 payment;
        assembly {
            payment := shr(128, mload(add(completeData, 0x20)))
        }

        assertEq(payment, 0, "Native token payment should be zero");
    }

    /// @notice Test with single token to verify format consistency
    function test_singleToken_returnDataFormat(uint128 initialAmount, uint128 paymentAmount) public {
        // Bound amounts to reasonable values
        initialAmount = uint128(bound(initialAmount, 0, type(uint128).max / 2));
        paymentAmount = uint128(bound(paymentAmount, 0, type(uint128).max / 2));

        // Setup: Give tokens to core and test locker
        if (initialAmount > 0) token0.transfer(address(core), initialAmount);
        if (paymentAmount > 0) token0.transfer(address(testLocker), paymentAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);

        (bytes memory startData, bytes memory completeData) =
            testLocker.testStartAndCompletePayments(tokens, paymentAmount, 0);

        // Verify startPayments format for single token
        assertEq(startData.length, 32, "Should return 32 bytes for 1 token");

        uint256 returnedBalance;
        assembly {
            returnedBalance := mload(add(startData, 0x20))
        }
        assertEq(returnedBalance, initialAmount, "Balance should match");

        // Verify completePayments format for single token
        assertEq(completeData.length, 16, "Should return 16 bytes for 1 token");

        uint128 returnedPayment;
        assembly {
            returnedPayment := shr(128, mload(add(completeData, 0x20)))
        }

        assertEq(returnedPayment, paymentAmount, "Payment amount should match");
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

    /// @notice Test both startPayments and completePayments with multiple tokens
    function testStartAndCompletePaymentsMultiple(address[] memory tokens, uint256[] memory amounts)
        external
        returns (bytes memory startData, bytes memory completeData)
    {
        return abi.decode(lock(abi.encode("startAndCompleteMultiple", tokens, amounts)), (bytes, bytes));
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
        } else if (keccak256(bytes(action)) == keccak256(bytes("startAndCompleteMultiple"))) {
            (, address[] memory tokens, uint256[] memory amounts) = abi.decode(data, (string, address[], uint256[]));

            // Call startPayments
            bytes memory startCallData = abi.encodeWithSelector(IFlashAccountant.startPayments.selector);
            for (uint256 i = 0; i < tokens.length; i++) {
                startCallData = abi.encodePacked(startCallData, abi.encode(tokens[i]));
            }

            (bool startSuccess, bytes memory startData) = address(ACCOUNTANT).call(startCallData);
            require(startSuccess, "startPayments failed");

            // Transfer tokens to the accountant
            for (uint256 i = 0; i < tokens.length && i < amounts.length; i++) {
                if (amounts[i] > 0) {
                    TestToken(tokens[i]).transfer(address(ACCOUNTANT), amounts[i]);
                }
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
        }

        revert("Unknown action");
    }

    receive() external payable {}
}
