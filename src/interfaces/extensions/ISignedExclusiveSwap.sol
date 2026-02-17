// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../../types/poolKey.sol";
import {SwapParameters} from "../../types/swapParameters.sol";
import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

/// @notice Forward payload for signed exclusive swaps.
struct SignedSwapPayload {
    PoolKey poolKey;
    SwapParameters params;
    address authorizedLocker;
    uint64 deadline;
    uint64 extraFee;
    uint256 nonce;
    bytes signature;
}

/// @title Signed Exclusive Swap Interface
/// @notice Extension that enforces forward-only swaps and applies signed, per-swap fee controls.
interface ISignedExclusiveSwap is IExposedStorage, ILocker, IForwardee, IExtension {
    /// @notice Thrown when attempting to swap directly without using forward.
    error SwapMustHappenThroughForward();

    /// @notice Thrown when the signed payload is expired.
    error SignatureExpired();

    /// @notice Thrown when signature verification fails.
    error InvalidSignature();

    /// @notice Thrown when the payload constrains usage to a locker and a different locker attempts use.
    error UnauthorizedLocker();

    /// @notice Thrown when a nonce has already been consumed.
    error NonceAlreadyUsed();

    /// @notice Public entrypoint to donate pending extension-collected fees to LPs.
    function accumulatePoolFees(PoolKey memory poolKey) external;
}
