// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FlashAccountant
/// @notice Abstract contract that provides flash loan accounting functionality using transient storage
/// @dev This contract manages debt tracking for flash loans, allowing users to borrow tokens temporarily
///      and ensuring all debts are settled before the transaction completes. Uses transient storage
///      for gas-efficient temporary state management within a single transaction.
abstract contract FlashAccountant is IFlashAccountant {
    // These offsets are selected so that they do not accidentally overlap with any other base contract's use of transient storage

    /// @dev Transient storage slot for tracking the current locker ID and address
    /// @dev The stored ID is kept as id + 1 to facilitate the NotLocked check (zero means unlocked)
    /// @dev Generated using: cast keccak "FlashAccountant#CURRENT_LOCKER_SLOT"
    uint256 private constant _CURRENT_LOCKER_SLOT = 0x07cc7f5195d862f505d6b095c82f92e00cfc1766f5bca4383c28dc5fca1555fd;

    /// @dev Transient storage offset for tracking the count of tokens with non-zero debt for each locker
    /// @dev Generated using: cast keccak "FlashAccountant#NONZERO_DEBT_COUNT_OFFSET"
    uint256 private constant _NONZERO_DEBT_COUNT_OFFSET =
        0x7772acfd7e0f66ebb20a058830296c3dc1301b111d23348e1c961d324223190d;

    /// @dev Transient storage offset for tracking token balances during payment operations
    /// @dev Generated using: cast keccak "FlashAccountant#_PAYMENT_TOKEN_ADDRESS_OFFSET"
    uint256 private constant _PAYMENT_TOKEN_ADDRESS_OFFSET =
        0x6747da56dbd05b26a7ecd2a0106781585141cf07098ad54c0e049e4e86dccb8c;

    /// @notice Gets the current locker information from transient storage
    /// @dev Reverts with NotLocked() if no lock is currently active
    /// @return id The unique identifier for the current lock
    /// @return locker The address of the current locker
    function _getLocker() internal view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            let current := tload(_CURRENT_LOCKER_SLOT)

            if iszero(current) {
                // cast sig "NotLocked()"
                mstore(0, shl(224, 0x1834e265))
                revert(0, 4)
            }

            id := sub(shr(160, current), 1)
            locker := shr(96, shl(96, current))
        }
    }

    /// @notice Gets the current locker information and ensures the caller is the locker
    /// @dev Reverts with LockerOnly() if the caller is not the current locker
    /// @return id The unique identifier for the current lock
    /// @return locker The address of the current locker (which must be msg.sender)
    function _requireLocker() internal view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
        if (locker != msg.sender) revert LockerOnly();
    }

    /// @notice Updates the debt tracking for a specific locker and token
    /// @dev We assume debtChange cannot exceed a 128 bits value, even though it uses a int256 container.
    ///      This must be enforced at the places it is called for this contract's safety.
    ///      Negative values erase debt, positive values add debt.
    ///      Updates the non-zero debt count when debt transitions between zero and non-zero states.
    /// @param id The locker ID to update debt for
    /// @param token The token address to update debt for
    /// @param debtChange The change in debt (negative to reduce, positive to increase)
    function _accountDebt(uint256 id, address token, int256 debtChange) internal {
        assembly ("memory-safe") {
            if iszero(iszero(debtChange)) {
                mstore(0, add(shl(160, id), token))
                let deltaSlot := keccak256(0, 32)
                let current := tload(deltaSlot)

                // we know this never overflows because debtChange is only ever derived from 128 bit values in inheriting contracts
                let next := add(current, debtChange)

                let nextZero := iszero(next)
                if xor(iszero(current), nextZero) {
                    let nzdCountSlot := add(id, _NONZERO_DEBT_COUNT_OFFSET)

                    tstore(nzdCountSlot, add(sub(tload(nzdCountSlot), nextZero), iszero(nextZero)))
                }

                tstore(deltaSlot, next)
            }
        }
    }

    /// @notice Updates debt for the current locker, for the token at the calling address
    /// @dev This is for deeply-integrated tokens that allow flash operations via the accountant.
    ///      The calling address is treated as the token address.
    /// @param delta The change in debt (must fit within int128 bounds)
    function updateDebt(int256 delta) external {
        (uint256 id,) = _getLocker();
        if (delta > type(int128).max || delta < type(int128).min) revert UpdateDebtOverflow();
        _accountDebt(id, msg.sender, delta);
    }

    /// @notice Creates a lock context and calls back to the caller's locked function
    /// @dev The entrypoint for all operations on the core contract. Any data passed after the
    ///      function signature is passed through back to the caller after the locked function
    ///      signature and data, with no additional encoding. Any data returned from ILocker#locked
    ///      is also returned from this function exactly as is. Reverts are bubbled up.
    ///      Ensures all debts are zeroed before completing the lock.
    function lock() external {
        assembly ("memory-safe") {
            let current := tload(_CURRENT_LOCKER_SLOT)

            let id := shr(160, current)

            // store the count
            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), caller()))

            let free := mload(0x40)
            // Prepare call to locked(uint256) -> selector 0xb45a3c0e
            mstore(free, shl(224, 0xb45a3c0e))
            mstore(add(free, 4), id) // ID argument

            calldatacopy(add(free, 36), 4, sub(calldatasize(), 4))

            // Call the original caller with the packed data
            let success := call(gas(), caller(), 0, free, add(calldatasize(), 32), 0, 0)

            // Pass through the error on failure
            if iszero(success) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            // Undo the "locker" state changes
            tstore(_CURRENT_LOCKER_SLOT, current)

            // Check if something is nonzero
            let nonzeroDebtCount := tload(add(_NONZERO_DEBT_COUNT_OFFSET, id))
            if nonzeroDebtCount {
                // cast sig "DebtsNotZeroed(uint256)"
                mstore(0x00, 0x9731ba37)
                mstore(0x20, id)
                revert(0x1c, 0x24)
            }

            // Directly return whatever the subcall returned
            returndatacopy(free, 0, returndatasize())
            return(free, returndatasize())
        }
    }

    /// @notice Forwards the lock context to another actor, allowing them to act on the original locker's debt
    /// @dev Temporarily changes the locker to the forwarded address for the duration of the forwarded call.
    ///      Any additional calldata is passed through to the forwardee with no additional encoding.
    ///      Any data returned from IForwardee#forwarded is returned exactly as is. Reverts are bubbled up.
    /// @param to The address to forward the lock context to
    function forward(address to) external {
        (uint256 id, address locker) = _requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), to))

            let free := mload(0x40)

            // Prepare call to forwarded(uint256,address) -> selector 0x64919dea
            mstore(free, shl(224, 0x64919dea))
            mstore(add(free, 4), id)
            mstore(add(free, 36), locker)

            calldatacopy(add(free, 68), 36, sub(calldatasize(), 36))

            // Call the forwardee with the packed data
            let success := call(gas(), to, 0, free, add(32, calldatasize()), 0, 0)

            // Pass through the error on failure
            if iszero(success) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), locker))

            // Directly return whatever the subcall returned
            returndatacopy(free, 0, returndatasize())
            return(free, returndatasize())
        }
    }

    /// @notice Initiates a payment operation by recording current token balances
    /// @dev To make a payment to core, you must first call startPayments with all the tokens you'd like to send.
    ///      All the tokens that will be paid must be ABI-encoded immediately after the 4 byte function selector.
    ///      This function stores the current balance + 1 for each token to distinguish between zero balance
    ///      and uninitialized state. Returns the current balances of all specified tokens as ABI-encoded
    ///      raw bytes via assembly (no explicit Solidity return type).
    function startPayments() external {
        assembly ("memory-safe") {
            // 0-52 are used for the balanceOf calldata
            mstore(20, address()) // Store the `account` argument.
            mstore(0, 0x70a08231000000000000000000000000) // `balanceOf(address)`.

            let free := mload(0x40)

            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } {
                // clean upper 96 bits of the token argument at i
                let token := shr(96, shl(96, calldataload(i)))

                let returnLocation := add(free, sub(i, 4))

                let tokenBalance :=
                    mul( // The arguments of `mul` are evaluated from right to left.
                        mload(returnLocation),
                        and( // The arguments of `and` are evaluated from right to left.
                            gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                            staticcall(gas(), token, 0x10, 0x24, returnLocation, 0x20)
                        )
                    )

                tstore(add(_PAYMENT_TOKEN_ADDRESS_OFFSET, token), add(tokenBalance, 1))
            }

            return(free, sub(calldatasize(), 4))
        }
    }

    /// @notice Completes a payment operation by calculating and crediting token payments
    /// @dev After tokens have been transferred, call completePayments to be credited for the tokens
    ///      that have been paid to core. The credit goes to the current locker. Compares current
    ///      balances with those recorded in startPayments to determine payment amounts.
    ///      The computed payments are applied to the current locker's debt.
    function completePayments() external {
        (uint256 id,) = _getLocker();

        assembly ("memory-safe") {
            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } {
                let token := shr(96, shl(96, calldataload(i)))

                let offset := add(_PAYMENT_TOKEN_ADDRESS_OFFSET, token)
                let lastBalance := tload(offset)
                tstore(offset, 0)

                mstore(20, address()) // Store the `account` argument.
                mstore(0, 0x70a08231000000000000000000000000) // `balanceOf(address)`.

                let currentBalance :=
                    mul( // The arguments of `mul` are evaluated from right to left.
                        mload(0),
                        and( // The arguments of `and` are evaluated from right to left.
                            gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                            staticcall(gas(), token, 0x10, 0x24, 0, 0x20)
                        )
                    )

                let payment :=
                    mul(
                        and(gt(lastBalance, 0), not(lt(currentBalance, lastBalance))),
                        sub(currentBalance, sub(lastBalance, 1))
                    )

                // We never expect tokens to have this much total supply
                if shr(128, payment) {
                    // cast sig "PaymentOverflow()"
                    mstore(0x00, 0x9cac58ca)
                    revert(0x1c, 4)
                }

                if iszero(iszero(payment)) {
                    mstore(0, add(shl(160, id), token))
                    let deltaSlot := keccak256(0, 32)
                    let current := tload(deltaSlot)

                    // never overflows because of the payment overflow check that bounds payment to 128 bits
                    let next := sub(current, payment)

                    let nextZero := iszero(next)
                    if xor(iszero(current), nextZero) {
                        let nzdCountSlot := add(id, _NONZERO_DEBT_COUNT_OFFSET)

                        tstore(nzdCountSlot, add(sub(tload(nzdCountSlot), nextZero), iszero(nextZero)))
                    }

                    tstore(deltaSlot, next)
                }
            }
        }
    }

    /// @notice Withdraws tokens from the accountant to recipients using packed calldata
    /// @dev The contract must be locked, as it tracks withdrawn amounts against the current locker's debt.
    ///      Calldata format: each withdrawal is 56 bytes: token (20) + recipient (20) + amount (16)
    ///      For native tokens, uses the NATIVE_TOKEN_ADDRESS constant and transfers ETH directly.
    function withdraw() external {
        (uint256 id,) = _requireLocker();

        // Validate calldata length to ensure complete tuples
        if ((msg.data.length - 4) % 56 != 0) {
            revert InvalidPackedCalldataLength();
        }

        // Process each withdrawal entry
        for (uint256 i = 4; i < msg.data.length; i += 56) {
            address token;
            address recipient;
            uint128 amount;

            assembly ("memory-safe") {
                token := shr(96, calldataload(i))
                recipient := shr(96, calldataload(add(i, 20)))
                amount := shr(128, calldataload(add(i, 40)))
            }

            if (amount > 0) {
                // Update debt using existing function for consistency
                _accountDebt(id, token, int256(uint256(amount)));

                // Perform the withdrawal
                if (token == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(recipient, amount);
                } else {
                    SafeTransferLib.safeTransfer(token, recipient, amount);
                }
            }
        }
    }

    /// @notice Receives ETH payments and credits them against the current locker's native token debt
    /// @dev This contract can receive ETH as a payment. The received amount is credited as a negative
    ///      debt change for the native token. Note: because we use msg.value here, this contract can
    ///      never be multicallable, i.e. it should never expose the ability to delegatecall itself
    ///      more than once in a single call.
    receive() external payable {
        (uint256 id,) = _getLocker();

        // Note because we use msg.value here, this contract can never be multicallable, i.e. it should never expose the ability
        //      to delegatecall itself more than once in a single call
        unchecked {
            // We never expect the native token to exceed this supply
            if (msg.value > type(uint128).max) revert PaymentOverflow();

            _accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
        }
    }
}
