// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {TokenWrapper} from "./TokenWrapper.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";

contract TokenWrapperPeriphery is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function wrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, int256(uint256(amount))));
    }

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, -int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, -int256(uint256(amount))));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, int256 amount) =
            abi.decode(data, (TokenWrapper, address, address, int256));

        if (amount >= 0) {
            // this creates the deltas
            forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            accountant.withdraw(address(wrapper), recipient, uint128(uint256(amount)));
            // and pay the wrapped token from the payer
            pay(payer, address(wrapper.underlyingToken()), uint256(amount));
        } else {
            // this creates the deltas
            forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            accountant.withdraw(address(wrapper.underlyingToken()), recipient, uint128(uint256(-amount)));
            // and pay the wrapped token from the payer
            pay(payer, address(wrapper), uint256(-amount));
        }
    }
}
