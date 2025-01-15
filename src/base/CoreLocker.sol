// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core, ILocker} from "../Core.sol";

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
        return core.lock(data);
    }

    function handleLockData(bytes calldata data) internal virtual returns (bytes memory result);
}
