// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Locker} from "../types/locker.sol";

interface ILocker {
    function locked_6416899205(uint256 id) external;
}

interface IForwardee {
    function forwarded_2374103877(Locker original) external;
}

/// @title IFlashAccountant
/// @notice Interface for flash loan accounting functionality using transient storage
/// @dev This interface manages debt tracking for flash loans, allowing users to borrow tokens temporarily
///      and ensuring all debts are settled before the transaction completes. Uses transient storage
///      for gas-efficient temporary state management within a single transaction.
interface IFlashAccountant {
    /// @notice Thrown when an operation is made that affects debts without an active lock
    error NotLocked();
    /// @notice Thrown when a method is called by an address other than the current locker
    error LockerOnly();
    /// @notice Thrown when the lock callback returns without clearing all the debts either via withdrawing from or paying to the accountant
    error DebtsNotZeroed(uint256 id);
    /// @notice Thrown if the contract receives a payment that exceeds type(uint128).max
    error PaymentOverflow();
    /// @notice Thrown if the contract receives a call to updateDebt that has a data length != 20
    error UpdateDebtMessageLength();

    /// @notice Creates a lock context and calls back to the caller's locked function
    /// @dev The entrypoint for all operations on the core contract. Any data passed after the
    ///      function signature is passed through back to the caller after the locked function
    ///      signature and data, with no additional encoding. Any data returned from ILocker#locked
    ///      is also returned from this function exactly as is. Reverts are bubbled up.
    ///      Ensures all debts are zeroed before completing the lock.
    function lock() external;

    /// @notice Forwards the lock context to another actor, allowing them to act on the original locker's debt
    /// @dev Temporarily changes the locker to the forwarded address for the duration of the forwarded call.
    ///      Any additional calldata is passed through to the forwardee with no additional encoding.
    ///      Any data returned from IForwardee#forwarded is returned exactly as is. Reverts are bubbled up.
    /// @param to The address to forward the lock context to
    function forward(address to) external;

    /// @notice Initiates a payment operation by recording current token balances
    /// @dev To make a payment to core, you must first call startPayments with all the tokens you'd like to send.
    ///      All the tokens that will be paid must be ABI-encoded immediately after the 4 byte function selector.
    ///      This function stores the current balance + 1 for each token to distinguish between zero balance
    ///      and uninitialized state. Returns the current balances of all specified tokens as ABI-encoded
    ///      raw bytes via assembly (no explicit Solidity return type).
    function startPayments() external;

    /// @notice Completes a payment operation by calculating and crediting token payments
    /// @dev After tokens have been transferred, call completePayments to be credited for the tokens
    ///      that have been paid to core. The credit goes to the current locker. Compares current
    ///      balances with those recorded in startPayments to determine payment amounts.
    ///      The computed payments are applied to the current locker's debt.
    ///      Returns packed uint128 payment amounts (16 bytes each) in the same order as the tokens.
    function completePayments() external;

    /// @notice Withdraws tokens from the accountant to recipients using packed calldata
    /// @dev The contract must be locked, as it tracks withdrawn amounts against the current locker's debt.
    ///      Calldata format: each withdrawal is 56 bytes: token (20) + recipient (20) + amount (16)
    ///      For native tokens, uses the NATIVE_TOKEN_ADDRESS constant and transfers ETH directly.
    function withdraw() external;

    /// @notice Updates debt for the current locker and for the token at the calling address
    /// @dev This is for deeply-integrated tokens that allow flash operations via the accountant.
    ///      The calling address is treated as the token address.
    /// @dev The debt change argument is an int128 encoded immediately after the selector.
    /// @dev The calldata length must be exactly 20 bytes in order to avoid this being called unintentionally.
    function updateDebt() external;

    /// @notice Receives ETH payments and credits them against the current locker's native token debt
    /// @dev This contract can receive ETH as a payment. The received amount is credited as a negative
    ///      debt change for the native token. Note: because we use msg.value here, this contract can
    ///      never be multicallable, i.e. it should never expose the ability to delegatecall itself
    ///      more than once in a single call.
    receive() external payable;
}
