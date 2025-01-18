// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core, ILocker} from "../Core.sol";

import {TransfersTokens} from "./TransfersTokens.sol";

abstract contract CoreLocker is ILocker, TransfersTokens {
    Core internal immutable core;

    constructor(Core _core) {
        core = _core;
    }

    error CoreOnly();

    function locked(uint256, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(core)) revert CoreOnly();
        return handleLockData(data);
    }

    function lock(bytes memory data) internal returns (bytes memory result) {
        result = core.lock(data);
    }

    function payCore(address from, address token, uint256 amount) internal {
        if (amount > 0) {
            core.startPayment(token);
            transferTokenFrom(token, from, address(core), amount);
            core.completePayment(token);
        }
    }

    function withdrawFromCore(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            core.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes calldata data) internal virtual returns (bytes memory result);
}
