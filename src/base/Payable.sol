// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {WETH} from "solady/tokens/WETH.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

// Allows a contract to receive a balance which it holds transiently
// Because it only holds balances transiently, it must be multicallable, otherwise it cannot safely be used by EOAs
abstract contract Payable is Multicallable {
    // The WETH address is used for wrapping ETH
    WETH private immutable weth;

    constructor(WETH _weth) {
        weth = _weth;
    }

    // Takes the given token amount from the allowance of the caller
    function pay(address token, uint256 amount) external {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
    }

    // Wraps all ETH held in this contract
    function wrapETH() external payable {
        weth.deposit{value: address(this).balance}();
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

    receive() external payable {}
}
