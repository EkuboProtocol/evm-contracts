// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core, ILocker} from "../Core.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TransfersTokens, NATIVE_TOKEN_ADDRESS} from "./TransfersTokens.sol";

abstract contract CoreLocker is ILocker, TransfersTokens {
    Core internal immutable core;

    constructor(Core _core) {
        core = _core;
    }

    error CoreOnly();

    modifier onlyCore() {
        if (msg.sender != address(core)) revert CoreOnly();
        _;
    }

    function locked(uint256, bytes calldata data) external onlyCore returns (bytes memory) {
        return handleLockData(data);
    }

    function payCallback(uint256 id, address token, bytes memory data) external onlyCore returns (bytes memory) {
        (address from, uint256 amount) = abi.decode(data, (address, uint256));
        transferTokenFrom(token, from, address(core), amount);
    }

    function lock(bytes memory data) internal returns (bytes memory result) {
        result = core.lock(data);
    }

    function payCore(address from, address token, uint256 amount) internal {
        if (amount > 0) {
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(core), amount);
            } else {
                core.pay(token, abi.encode(from, amount));
            }
        }
    }

    function withdrawFromCore(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            core.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes calldata data) internal virtual returns (bytes memory result);
}
