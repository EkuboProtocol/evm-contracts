// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {TokenWrapper} from "./TokenWrapper.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";

contract WrappedTokenMinter is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function wrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, amount));
    }

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, uint128 amount) =
            abi.decode(data, (TokenWrapper, address, address, uint128));

        // this creates the deltas
        forward(address(wrapper), abi.encode(uint256(0), amount));
        // now withdraw to the recipient
        accountant.withdraw(address(wrapper), recipient, amount);
        // and pay the wrapped token from the payer
        pay(payer, address(wrapper.underlyingToken()), amount);
    }
}

contract WrappedTokenBurner is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function unwrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, amount));
    }

    function unwrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, uint128 amount) =
            abi.decode(data, (TokenWrapper, address, address, uint128));

        // this creates the deltas
        forward(address(wrapper), abi.encode(uint256(1), amount));
        // now withdraw to the recipient
        accountant.withdraw(address(wrapper.underlyingToken()), recipient, amount);
        // and pay the wrapped token from the payer
        pay(payer, address(wrapper), amount);
    }
}
