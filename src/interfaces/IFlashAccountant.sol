// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

interface ILocker {
    function locked(uint256 id, bytes calldata data) external returns (bytes memory);
}

interface IForwardee {
    function forwarded(address locker, uint256 id, bytes calldata data) external returns (bytes memory);
}

interface IFlashAccountant {
    error NotLocked();
    error DebtsNotZeroed();
    error LockerOnly();

    // Create a lock context
    function lock(bytes calldata data) external returns (bytes memory result);

    // Forward the lock for the given locker
    function forward(address to, bytes calldata data) external returns (bytes memory result);
}
