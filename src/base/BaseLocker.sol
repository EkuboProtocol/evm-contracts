// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ILocker, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";

/// @title Base Locker
/// @notice Abstract base contract for contracts that need to interact with the flash accountant
/// @dev Provides locking functionality and token transfer utilities
abstract contract BaseLocker is ILocker {
    /// @notice Thrown when a function is called by an address other than the accountant
    error BaseLockerAccountantOnly();

    /// @notice The flash accountant contract that manages locks and token transfers
    IFlashAccountant internal immutable ACCOUNTANT;

    /// @notice Constructs the BaseLocker with a flash accountant
    /// @param _accountant The flash accountant contract
    constructor(IFlashAccountant _accountant) {
        ACCOUNTANT = _accountant;
    }

    /// CALLBACK HANDLERS

    /// @inheritdoc ILocker
    function locked_6416899205(uint256 id) external {
        if (msg.sender != address(ACCOUNTANT)) revert BaseLockerAccountantOnly();

        bytes memory data = msg.data[36:];

        bytes memory result = handleLockData(id, data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    /// INTERNAL FUNCTIONS

    /// @notice Acquires a lock and executes the provided data
    /// @dev Internal function that calls the accountant's lock function
    /// @param data The data to execute within the lock
    /// @return result The result of the lock execution
    function lock(bytes memory data) internal returns (bytes memory result) {
        address target = address(ACCOUNTANT);

        assembly ("memory-safe") {
            // We will store result where the free memory pointer is now, ...
            result := mload(0x40)

            // But first use it to store the calldata

            // Selector of lock()
            mstore(result, shl(224, 0xf83d08ba))

            // We only copy the data, not the length, because the length is read from the calldata size
            let len := mload(data)
            mcopy(add(result, 4), add(data, 32), len)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, result, add(len, 4), 0, 0)) {
                returndatacopy(result, 0, returndatasize())
                revert(result, returndatasize())
            }

            // Copy the entire return data into the space where the result is pointing
            mstore(result, returndatasize())
            returndatacopy(add(result, 32), 0, returndatasize())

            // Update the free memory pointer to be after the end of the data, aligned to the next 32 byte word
            mstore(0x40, and(add(add(result, add(32, returndatasize())), 31), not(31)))
        }
    }

    /// @notice Thrown when a lock was expected to revert but didn't
    error ExpectedRevertWithinLock();

    /// @notice Acquires a lock expecting it to revert and returns the revert data
    /// @dev Used for quote functions that use reverts to return data
    /// @param data The data to execute within the lock
    /// @return result The revert data from the lock execution
    function lockAndExpectRevert(bytes memory data) internal returns (bytes memory result) {
        address target = address(ACCOUNTANT);

        assembly ("memory-safe") {
            // We will store result where the free memory pointer is now, ...
            result := mload(0x40)

            // But first use it to store the calldata

            // Selector of lock()
            mstore(result, shl(224, 0xf83d08ba))

            // We only copy the data, not the length, because the length is read from the calldata size
            let len := mload(data)
            mcopy(add(result, 4), add(data, 32), len)

            // If the call succeeded, revert with ExpectedRevertWithinLock.selector
            if call(gas(), target, 0, result, add(len, 4), 0, 0) {
                mstore(0, shl(224, 0x4c816e2b))
                revert(0, 4)
            }

            // Copy the entire revert data into the space where the result is pointing
            mstore(result, returndatasize())
            returndatacopy(add(result, 32), 0, returndatasize())

            // Update the free memory pointer to be after the end of the data, aligned to the next 32 byte word
            mstore(0x40, and(add(add(result, add(32, returndatasize())), 31), not(31)))
        }
    }

    /// @notice Handles the execution of lock data
    /// @dev Must be implemented by derived contracts to define lock behavior
    /// @param id The lock ID
    /// @param data The data to process within the lock
    /// @return result The result of processing the lock data
    function handleLockData(uint256 id, bytes memory data) internal virtual returns (bytes memory result);
}
