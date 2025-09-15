// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

interface ILocker {
    function locked(uint256 id) external;
}

interface IForwardee {
    function forwarded(uint256 id, address originalLocker) external;
}

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

    // Create a lock context
    // Any data passed after the function signature is passed through back to the caller after the locked function signature and data, with no additional encoding
    // In addition, any data returned from ILocker#locked is also returned from this function exactly as is, i.e. with no additional encoding or decoding
    // Reverts are also bubbled up
    function lock() external;

    // Forward the lock from the current locker to the given address
    // Any additional calldata is also passed through to the forwardee, with no additional encoding
    // In addition, any data returned from IForwardee#forwarded is also returned from this function exactly as is, i.e. with no additional encoding or decoding
    // Reverts are also bubbled up
    function forward(address to) external;

    // To make a payment to core, you must first call startPayments with all the tokens you'd like to send.
    // All the tokens that will be paid must be ABI-encoded immediately after the 4 byte function selector.
    // The current balance of all the tokens will be returned, ABI-encoded.
    function startPayments() external;
    // After the tokens have been transferred, you must call completePayments to be credited for the tokens that have been paid to core.
    // The credit goes to the current locker.
    // The computed payments for each respective token will be returned, ABI-encoded.
    function completePayments() external;

    // Withdraws a token amount from the accountant to the given recipient.
    // The contract must be locked, as it tracks the withdrawn amount against the current locker's delta.
    function withdraw(address token, address recipient, uint128 amount) external;

    // Updates debt for the current locker, for the token at the calling address. This is for deeply-integrated tokens that allow flash operations via the accountant.
    function updateDebt(int256 delta) external;

    // This contract can receive ETH as a payment as well
    receive() external payable;
}
