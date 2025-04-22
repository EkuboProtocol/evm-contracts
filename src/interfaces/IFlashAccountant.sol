// SPDX-License-Identifier: UNLICENSED
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

    // Pays the given amount of token, by calling the payCallback function on the caller to afford them the opportunity to make the payment.
    // This function, unlike lock and forward, does not return any of the returndata from the callback.
    // This function also cannot be re-entered like lock and forward.
    // Must be locked, as the contract accounts the payment against the current locker's debts.
    // Token must not be the NATIVE_TOKEN_ADDRESS, as the `balanceOf` calls will fail.
    // If you want to pay in the chain's native token, simply transfer it to this contract using a call.
    // The payer must implement payCallback in which they must transfer the token to Core.
    function startPayment(address token) external returns (uint256 balance);
    function completePayment(address token) external returns (uint256 payment);

    // Withdraws a token amount from the accountant to the given recipient.
    // The contract must be locked, as it tracks the withdrawn amount against the current locker's delta.
    function withdraw(address token, address recipient, uint128 amount) external;

    // This contract can receive ETH as a payment as well
    receive() external payable;
}
