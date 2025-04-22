// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

abstract contract BaseLocker is ILocker {
    error BaseLockerAccountantOnly();

    IFlashAccountant internal immutable accountant;

    constructor(IFlashAccountant _accountant) {
        accountant = _accountant;
    }

    /// CALLBACK HANDLERS

    function locked(uint256 id) external {
        if (msg.sender != address(accountant)) revert BaseLockerAccountantOnly();

        bytes memory data = msg.data[36:];

        bytes memory result = handleLockData(id, data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    /// INTERNAL FUNCTIONS

    function lock(bytes memory data) internal returns (bytes memory result) {
        address target = address(accountant);

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

    error ExpectedRevertWithinLock();

    function lockAndExpectRevert(bytes memory data) internal returns (bytes memory result) {
        address target = address(accountant);

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

    function pay(address from, address token, uint256 amount) internal {
        if (amount != 0) {
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(accountant), amount);
            } else {
                address target = address(accountant);

                assembly ("memory-safe") {
                    mstore(0, 0x30f6f092)
                    mstore(32, token)

                    // accountant.startPayment(token)
                    pop(call(gas(), target, 0, 0x1c, 36, 0x00, 0x00))

                    let m := mload(0x40) // Cache the free memory pointer.
                    mstore(0x60, amount) // Store the `amount` argument.
                    mstore(0x40, target) // Store the `to` argument.
                    mstore(0x2c, shl(96, from)) // Store the `from` argument.
                    mstore(0x0c, 0x23b872dd000000000000000000000000) // `transferFrom(address,address,uint256)`.
                    let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
                    if iszero(and(eq(mload(0x00), 1), success)) {
                        if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                            mstore(0x00, 0x7939f424) // `TransferFromFailed()`.
                            revert(0x1c, 0x04)
                        }
                    }
                    mstore(0x60, 0) // Restore the zero slot to zero.
                    mstore(0x40, m) // Restore the free memory pointer.

                    mstore(0, 0x51631ad2)
                    mstore(32, token)

                    // accountant.completePayment(token)
                    pop(call(gas(), target, 0, 0x1c, 36, 0x00, 0x00))
                }
            }
        }
    }

    function forward(address to, bytes memory data) internal returns (bytes memory result) {
        address target = address(accountant);

        assembly ("memory-safe") {
            // We will store result where the free memory pointer is now, ...
            result := mload(0x40)

            // But first use it to store the calldata

            // Selector of forward(address)
            mstore(result, shl(224, 0x101e8952))
            mstore(add(result, 4), to)

            // We only copy the data, not the length, because the length is read from the calldata size
            let len := mload(data)
            mcopy(add(result, 36), add(data, 32), len)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, result, add(36, len), 0, 0)) {
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

    function withdraw(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            accountant.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(uint256 id, bytes memory data) internal virtual returns (bytes memory result);
}
