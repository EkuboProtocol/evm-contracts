// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";

/// @title Flash Accountant Library
/// @notice Provides helper functions for interacting with the Flash Accountant
/// @dev Contains optimized assembly implementations for token payments to the accountant
library FlashAccountantLib {
    /// @notice Pays tokens directly to the flash accountant
    /// @dev Uses assembly for gas optimization and handles the payment flow with start/complete calls
    /// @param accountant The flash accountant contract to pay
    /// @param token The token address to pay
    /// @param amount The amount of tokens to pay
    function pay(IFlashAccountant accountant, address token, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0x00, 0xf9b6a796)
            mstore(0x20, token)

            // accountant.startPayments()
            pop(call(gas(), accountant, 0, 0x1c, 36, 0x00, 0x00))

            // token#transfer
            mstore(0x14, accountant) // Store the `to` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0xa9059cbb000000000000000000000000) // `transfer(address,uint256)`.
            // Perform the transfer, reverting upon failure.
            let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x90b8ec18) // `TransferFailed()`.
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.

            // accountant.completePayments()
            mstore(0x00, 0x12e103f1)
            mstore(0x20, token)
            pop(call(gas(), accountant, 0, 0x1c, 36, 0x00, 0x00))
        }
    }

    /// @notice Pays tokens from a specific address to the flash accountant
    /// @dev Uses assembly for gas optimization and handles transferFrom with start/complete payment calls
    /// @param accountant The flash accountant contract to pay
    /// @param from The address to transfer tokens from
    /// @param token The token address to pay
    /// @param amount The amount of tokens to pay
    function payFrom(IFlashAccountant accountant, address from, address token, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0, 0xf9b6a796)
            mstore(32, token)

            // accountant.startPayments()
            pop(call(gas(), accountant, 0, 0x1c, 36, 0x00, 0x00))

            // token#transferFrom
            let m := mload(0x40)
            mstore(0x60, amount)
            mstore(0x40, accountant)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000) // `transferFrom(address,address,uint256)`.
            let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x7939f424) // `TransferFromFailed()`.
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)

            // accountant.completePayments()
            mstore(0x00, 0x12e103f1)
            mstore(0x20, token)
            pop(call(gas(), accountant, 0, 0x1c, 36, 0x00, 0x00))
        }
    }
}
