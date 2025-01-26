// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IPayer, IFlashAccountant, NATIVE_TOKEN_ADDRESS} from "../interfaces/IFlashAccountant.sol";
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
            result := mload(0x40)
            // selector of lock()
            mstore(result, shl(224, 0xf83d08ba))
            // then copy the data after the selector
            let len := mload(data)

            // we only copy the data, since the calldatasize implicitly encodes the length
            mcopy(add(result, 4), add(data, 32), len)

            // if it failed, pass through revert
            if iszero(call(gas(), target, 0, result, add(len, 36), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            mstore(result, returndatasize())
            returndatacopy(add(result, 32), 0, returndatasize())

            // we need 32 bytes for length plus the entire return data
            mstore(0x40, add(result, add(32, returndatasize())))

            // aligns the free memory pointer to the next greatest 32 bytes
            mstore(0x40, add(mload(0x40), 31))
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

    function withdraw(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            accountant.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes memory data) internal virtual returns (bytes memory result);
}
