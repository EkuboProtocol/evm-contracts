// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {WETH} from "solady/tokens/WETH.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// Allows a contract to receive a balance which it holds transiently
abstract contract Payable {
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

    receive() external payable {}
}
