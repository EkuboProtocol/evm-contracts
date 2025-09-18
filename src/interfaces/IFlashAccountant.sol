// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

interface ILocker {
    function locked(uint256 id) external;
}

interface IForwardee {
    function forwarded(uint256 id, address originalLocker) external;
}

/// @title IFlashAccountant
/// @notice Interface for flash loan accounting functionality using transient storage
/// @dev This interface manages debt tracking for flash loans, allowing users to borrow tokens temporarily
///      and ensuring all debts are settled before the transaction completes. Uses transient storage
///      for gas-efficient temporary state management within a single transaction.
interface IFlashAccountant {
    error NotLocked();
    error LockerOnly();
    error NoPaymentMade();
    error StartPaymentNotCalled();
    error DebtsNotZeroed(uint256 id);
    // Thrown if the contract receives too much payment in the payment callback or from a direct native token transfer
    error PaymentOverflow();
    error PayReentrance();
    // If updateDebt is called with an amount that does not fit within a int128 container, this error is thrown
    error UpdateDebtOverflow();
    // Thrown when withdraw calldata length is invalid
    error InvalidPackedCalldataLength();

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
    function completePayments() external;

    /// @notice Withdraws tokens from the accountant to recipients using packed calldata
    /// @dev The contract must be locked, as it tracks withdrawn amounts against the current locker's debt.
    ///      Calldata format: each withdrawal is 56 bytes: token (20) + recipient (20) + amount (16)
    ///      For native tokens, uses the NATIVE_TOKEN_ADDRESS constant and transfers ETH directly.
    function withdraw() external;

    /// @notice Updates debt for the current locker, for the token at the calling address
    /// @dev This is for deeply-integrated tokens that allow flash operations via the accountant.
    ///      The calling address is treated as the token address.
    /// @param delta The change in debt (must fit within int128 bounds)
    function updateDebt(int256 delta) external;

    /// @notice Receives ETH payments and credits them against the current locker's native token debt
    /// @dev This contract can receive ETH as a payment. The received amount is credited as a negative
    ///      debt change for the native token. Note: because we use msg.value here, this contract can
    ///      never be multicallable, i.e. it should never expose the ability to delegatecall itself
    ///      more than once in a single call.
    receive() external payable;
}
