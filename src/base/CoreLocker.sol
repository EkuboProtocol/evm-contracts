// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core, ILocker} from "../Core.sol";

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

abstract contract CoreLocker is ILocker {
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

    function payCore(address token, uint256 amount) internal {
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, address(core), amount);
            core.pay(token);
        }
    }

    function withdrawFromCore(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            core.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes calldata data) internal virtual returns (bytes memory result);
}
