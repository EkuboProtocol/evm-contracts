// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";
import {PoolBalanceUpdate} from "../../types/poolBalanceUpdate.sol";
import {Bitmap} from "../../types/bitmap.sol";
import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

/// @title Signed Exclusive Swap Interface
/// @notice Extension that enforces forward-only swaps and applies signed, per-swap fee controls.
interface ISignedExclusiveSwap is IExposedStorage, ILocker, IForwardee, IExtension {
    /// @notice Emitted when the default controller is updated.
    event DefaultControllerUpdated(address indexed controller, bool isEoa);

    /// @notice Emitted when a pool controller is updated.
    event PoolControllerUpdated(PoolId indexed poolId, address indexed controller, bool isEoa);

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

    /// @notice Thrown when the pool fee is non-zero.
    error PoolFeeMustBeZero();

    /// @notice Thrown when the signed minimum balance-update constraint is not met.
    error MinBalanceUpdateNotMet(PoolBalanceUpdate minBalanceUpdate, PoolBalanceUpdate actualBalanceUpdate);

    /// @notice Public entrypoint to donate pending extension-collected fees to LPs.
    function accumulatePoolFees(PoolKey memory poolKey) external;

    /// @notice Updates the default controller used for newly initialized pools.
    function setDefaultController(address controller, bool isEoa) external;

    /// @notice Sets a nonce bitmap word, allowing explicit nonce reuse/reset management.
    function setNonceBitmap(uint256 word, Bitmap bitmap) external;

    /// @notice Updates the controller for an existing pool.
    function setPoolController(PoolKey memory poolKey, address controller, bool isEoa) external;
}
