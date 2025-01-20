// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

// Has methods that are multicallable for checking deadlines and balance changes
// Necessarily multicallable, because these methods are expected to be called as part of another transaction that manipulates balances
// All methods are payable in case they are paired with other payable Multicallable calls
abstract contract SlippageChecker is Multicallable {
    error TransactionExpired(uint256 deadline);
    error MinimumOutputNotReceived(uint256 minimumOutput);
    error MaximumInputExceeded(uint256 maximumInput);

    function balanceKey(address sender, address token) private pure returns (bytes32 key) {
        assembly ("memory-safe") {
            mstore(0, sender)
            mstore(32, token)
            // 0x2ea13d3f0340a613d1765d6e239004eca4cb7efa2e253d1e113c4d333b8db7c8 == `cast keccak "SlippageChecker#balanceKey"`
            key := add(keccak256(0, 64), 0x2ea13d3f0340a613d1765d6e239004eca4cb7efa2e253d1e113c4d333b8db7c8)
        }
    }

    function getRecordedBalance(address token) private view returns (uint256 prev) {
        bytes32 key = balanceKey(msg.sender, token);
        assembly ("memory-safe") {
            prev := tload(key)
        }
    }

    function recordBalanceForSlippageCheck(address token) external payable {
        bytes32 key = balanceKey(msg.sender, token);
        uint256 bal = SafeTransferLib.balanceOf(token, msg.sender);
        assembly ("memory-safe") {
            tstore(key, bal)
        }
    }

    function checkDeadline(uint256 deadline) external payable {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
    }

    function checkMinimumOutputReceived(address token, uint256 minimumOutput) external payable {
        uint256 prev = getRecordedBalance(token);
        uint256 bal = SafeTransferLib.balanceOf(token, msg.sender);
        unchecked {
            if (bal < prev || (prev - bal) < minimumOutput) {
                revert MaximumInputExceeded(minimumOutput);
            }
        }
    }

    function checkMaximumInputNotExceeded(address token, uint256 maximumInput) external payable {
        uint256 prev = getRecordedBalance(token);
        uint256 bal = SafeTransferLib.balanceOf(token, msg.sender);
        unchecked {
            if (bal < prev && (prev - bal) > maximumInput) {
                revert MaximumInputExceeded(maximumInput);
            }
        }
    }
}
