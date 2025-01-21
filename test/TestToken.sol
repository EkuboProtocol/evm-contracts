// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

contract TestToken is ERC20 {
    constructor(address recipient) {
        _mint(recipient, type(uint256).max);
    }

    function name() public pure override returns (string memory) {
        return "TestToken";
    }

    function symbol() public pure override returns (string memory) {
        return "TT";
    }
}
