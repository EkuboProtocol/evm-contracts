// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

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
            // this is expected to never revert
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
            // we ignore the potential reverts in this case because it will almost always result in nonzero debt when the lock returns
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
            // this is expected to never revert
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
            // we ignore the potential reverts in this case because it will almost always result in nonzero debt when the lock returns
            pop(call(gas(), accountant, 0, 0x1c, 36, 0x00, 0x00))
        }
    }

    /// @notice Withdraws a single token using the old withdraw interface
    /// @dev Provides backward compatibility for the old withdraw(token, recipient, amount) signature
    /// @param accountant The flash accountant contract instance
    /// @param token The token address to withdraw
    /// @param recipient The address to receive the tokens
    /// @param amount The amount to withdraw
    function withdraw(IFlashAccountant accountant, address token, address recipient, uint128 amount) internal {
        assembly ("memory-safe") {
            let free := mload(0x40)

            // cast sig "withdraw()"
            mstore(free, shl(224, 0x3ccfd60b))

            // Pack: token (20 bytes) + recipient (20 bytes) + amount (16 bytes)
            mstore(add(free, 4), shl(96, token))
            mstore(add(free, 24), shl(96, recipient))
            mstore(add(free, 44), shl(128, amount))

            if iszero(call(gas(), accountant, 0, free, 60, 0, 0)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }
        }
    }

    /// @notice Pays two tokens from a specific address to the flash accountant in a single operation
    /// @dev Uses assembly for gas optimization and handles both tokens in a single startPayments/completePayments cycle
    /// @param accountant The flash accountant contract to pay
    /// @param from The address to transfer tokens from
    /// @param token0 The first token address to pay
    /// @param token1 The second token address to pay
    /// @param amount0 The amount of token0 to pay
    /// @param amount1 The amount of token1 to pay
    function payTwoFrom(
        IFlashAccountant accountant,
        address from,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        assembly ("memory-safe") {
            // Save free memory pointer before using 0x40
            let free := mload(0x40)

            // accountant.startPayments() with both tokens
            mstore(0x00, 0xf9b6a796) // startPayments selector
            mstore(0x20, token0) // first token
            mstore(0x40, token1) // second token

            // Call startPayments with both tokens (4 + 32 + 32 = 68 bytes)
            pop(call(gas(), accountant, 0, 0x1c, 68, 0x00, 0x00))

            // Restore free memory pointer
            mstore(0x40, free)

            // Transfer token0 from caller to accountant
            if amount0 {
                let m := mload(0x40)
                mstore(0x60, amount0)
                mstore(0x40, accountant)
                mstore(0x2c, shl(96, from))
                mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom selector
                let success := call(gas(), token0, 0, 0x1c, 0x64, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token0)), returndatasize()), success)) {
                        mstore(0x00, 0x7939f424) // TransferFromFailed()
                        revert(0x1c, 0x04)
                    }
                }
                mstore(0x60, 0)
                mstore(0x40, m)
            }

            // Transfer token1 from caller to accountant
            if amount1 {
                let m := mload(0x40)
                mstore(0x60, amount1)
                mstore(0x40, accountant)
                mstore(0x2c, shl(96, from))
                mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom selector
                let success := call(gas(), token1, 0, 0x1c, 0x64, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token1)), returndatasize()), success)) {
                        mstore(0x00, 0x7939f424) // TransferFromFailed()
                        revert(0x1c, 0x04)
                    }
                }
                mstore(0x60, 0)
                mstore(0x40, m)
            }

            // accountant.completePayments() with both tokens
            let free2 := mload(0x40)
            mstore(0x00, 0x12e103f1) // completePayments selector
            mstore(0x20, token0) // first token
            mstore(0x40, token1) // second token

            // Call completePayments with both tokens (4 + 32 + 32 = 68 bytes)
            pop(call(gas(), accountant, 0, 0x1c, 68, 0x00, 0x00))

            // Restore free memory pointer
            mstore(0x40, free2)
        }
    }

    /// @notice Withdraws two tokens using assembly to call withdraw with packed calldata
    /// @dev Uses assembly and packed calldata for gas efficiency, optimized for positions contract
    /// @param accountant The flash accountant contract instance
    /// @param token0 The first token address to withdraw
    /// @param token1 The second token address to withdraw
    /// @param recipient The address to receive both tokens
    /// @param amount0 The amount of token0 to withdraw
    /// @param amount1 The amount of token1 to withdraw
    function withdrawTwo(
        IFlashAccountant accountant,
        address token0,
        address token1,
        address recipient,
        uint128 amount0,
        uint128 amount1
    ) internal {
        assembly ("memory-safe") {
            let free := mload(0x40)

            // cast sig "withdraw()"
            mstore(free, shl(224, 0x3ccfd60b))

            // Pack first withdrawal: token0 (20 bytes) + recipient (20 bytes) + amount0 (16 bytes)
            mstore(add(free, 4), shl(96, token0))
            mstore(add(free, 24), shl(96, recipient))
            mstore(add(free, 44), shl(128, amount0))

            // Pack second withdrawal: token1 (20 bytes) + recipient (20 bytes) + amount1 (16 bytes)
            mstore(add(free, 60), shl(96, token1))
            mstore(add(free, 80), shl(96, recipient))
            mstore(add(free, 100), shl(128, amount1))

            if iszero(call(gas(), accountant, 0, free, 116, 0, 0)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }
        }
    }

    /// @notice Forwards a call to another contract through the accountant
    /// @dev Used to call other contracts while maintaining the lock context
    /// @param accountant The flash accountant contract to forward through
    /// @param to The address to forward the call to
    /// @param data The call data to forward
    /// @return result The result of the forwarded call
    function forward(IFlashAccountant accountant, address to, bytes memory data)
        internal
        returns (bytes memory result)
    {
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
            if iszero(call(gas(), accountant, 0, result, add(36, len), 0, 0)) {
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

    /// @notice Calls updateDebt optimally
    /// @param accountant The flash accountant contract to forward through
    /// @param delta The change in delta for the caller token to effect on the accountant
    function updateDebt(IFlashAccountant accountant, int128 delta) internal {
        assembly ("memory-safe") {
            // cast sig "updateDebt()"
            mstore(0, 0x17c5da6a)
            mstore(32, shl(128, delta))

            if iszero(call(gas(), accountant, 0, 28, 20, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
