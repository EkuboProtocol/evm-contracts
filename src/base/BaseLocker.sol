// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IPayer, IForwardee, IFlashAccountant, NATIVE_TOKEN_ADDRESS} from "../interfaces/IFlashAccountant.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UsesCore} from "./UsesCore.sol";

abstract contract BaseLocker is ILocker, IPayer {
    IFlashAccountant private immutable accountant;

    constructor(IFlashAccountant _accountant) {
        accountant = _accountant;
    }

    /// CALLBACK HANDLERS

    function locked(uint256) external {
        require(msg.sender == address(accountant));

        bytes memory data = msg.data[36:];

        bytes memory result = handleLockData(data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    function payCallback(uint256, address token) external {
        require(msg.sender == address(accountant));

        address from;
        uint256 amount;
        assembly ("memory-safe") {
            from := calldataload(68)
            amount := calldataload(100)
        }

        SafeTransferLib.safeTransferFrom2(token, from, address(accountant), amount);
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
            if iszero(call(gas(), target, 0, result, add(len, 36), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            // Copy the entire return data into the space where the result is pointing
            mstore(result, returndatasize())
            returndatacopy(add(result, 32), 0, returndatasize())

            // Update the free memory pointer to be after the end of the data, aligned to the next 32 byte word
            mstore(0x40, and(add(add(result, add(32, returndatasize())), 31), not(31)))
        }
    }

    function pay(address from, address token, uint256 amount) internal {
        address target = address(accountant);

        if (amount > 0) {
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(accountant), amount);
            } else {
                assembly ("memory-safe") {
                    let free := mload(0x40)
                    // selector of pay(address)
                    mstore(free, shl(224, 0x0c11dedd))
                    mstore(add(free, 4), token)
                    mstore(add(free, 36), from)
                    mstore(add(free, 68), amount)

                    // if it failed, pass through revert
                    if iszero(call(gas(), target, 0, free, 100, 0, 0)) {
                        returndatacopy(0, 0, returndatasize())
                        revert(0, returndatasize())
                    }
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
            if iszero(call(gas(), target, 0, result, add(68, len), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
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

    function handleLockData(bytes memory data) internal virtual returns (bytes memory result);
}
