// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

interface ILocker {
    function locked(uint256 id) external;
}

interface IForwardee {
    function forwarded(address locker, uint256 id, bytes calldata data) external returns (bytes memory);
}

interface IFlashAccountant {
    error NotLocked();
    error DebtsNotZeroed();
    error LockerOnly();

    // Create a lock context
    // Any data passed after the function signature is passed through back to the caller after the locked function signature and data
    function lock() external;

    // Forward the lock for the given locker
    function forward(address to, bytes calldata data) external returns (bytes memory result);
}
