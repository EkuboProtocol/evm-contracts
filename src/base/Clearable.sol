// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {WETH} from "solady/tokens/WETH.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// For contracts that only hold balances transiently
abstract contract Clearable {
    // The WETH address is used for wrapping ETH
    WETH private immutable weth;

    constructor(WETH _weth) {
        weth = _weth;
    }

    error ClearMinimumBalanceNotReceived(address token, uint256 minimum, uint256 balance);

    function clearMinimumToRecipient(address token, uint256 minimum, address recipient) public {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance < minimum) revert ClearMinimumBalanceNotReceived(token, minimum, balance);
        SafeTransferLib.safeTransfer(token, recipient, balance);
    }

    function clearMinimum(address token, uint256 minimum) public {
        clearMinimumToRecipient(token, minimum, msg.sender);
    }

    function clear(address token) public {
        clearMinimumToRecipient(token, 0, msg.sender);
    }
}
