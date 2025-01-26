// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../interfaces/IFlashAccountant.sol";

// Has methods that are multicallable for checking deadlines and balance changes
// Only useful in multicallable context, because these methods are expected to be called as part of another transaction that manipulates balances
// All methods are payable in case they are paired with other payable Multicallable calls
abstract contract SlippageChecker {
    error TransactionExpired(uint256 deadline);
    error MinimumOutputNotReceived(address token, uint256 minimumOutput);
    error MaximumInputExceeded(address token, uint256 maximumInput);

    function balanceKey(address token, address account) private pure returns (bytes32 key) {
        assembly ("memory-safe") {
            mstore(0, token)
            mstore(32, account)
            // 0x2ea13d3f0340a613d1765d6e239004eca4cb7efa2e253d1e113c4d333b8db7c8 == `cast keccak "SlippageChecker#balanceKey"`
            key := add(keccak256(0, 64), 0x2ea13d3f0340a613d1765d6e239004eca4cb7efa2e253d1e113c4d333b8db7c8)
        }
    }

    function getRecordedBalance(address token, address account) private view returns (uint256 prev) {
        bytes32 key = balanceKey(token, account);
        assembly ("memory-safe") {
            prev := tload(key)
        }
    }

    function getBalance(address token, address account) private view returns (uint256 balance) {
        if (token == NATIVE_TOKEN_ADDRESS) {
            balance = account.balance;
        } else {
            balance = SafeTransferLib.balanceOf(token, account);
        }
    }

    function recordBalanceForSlippageCheck(address token) external payable {
        bytes32 key = balanceKey(token, msg.sender);
        uint256 bal = getBalance(token, msg.sender);
        assembly ("memory-safe") {
            tstore(key, bal)
        }
    }

    function checkDeadline(uint256 deadline) external payable {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
    }

    function checkMinimumOutputReceived(address token, uint256 minimumOutput) external payable {
        uint256 prev = getRecordedBalance(token, msg.sender);
        uint256 bal = getBalance(token, msg.sender);
        unchecked {
            if (bal < prev || (bal - prev) < minimumOutput) {
                revert MinimumOutputNotReceived(token, minimumOutput);
            }
        }
    }

    function checkMaximumInputNotExceeded(address token, uint256 maximumInput) external payable {
        uint256 prev = getRecordedBalance(token, msg.sender);
        uint256 bal = getBalance(token, msg.sender);
        unchecked {
            if (bal < prev && (prev - bal) > maximumInput) {
                revert MaximumInputExceeded(token, maximumInput);
            }
        }
    }

    // Allows a caller to refund any ETH sent to this contract for purpose of transient payments
    function refundNativeToken() external payable {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        }
    }
}
