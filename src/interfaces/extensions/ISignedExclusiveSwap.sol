// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";
import {PoolBalanceUpdate} from "../../types/poolBalanceUpdate.sol";
import {Bitmap} from "../../types/bitmap.sol";
import {SqrtRatio} from "../../types/sqrtRatio.sol";
import {ControllerAddress} from "../../types/controllerAddress.sol";
import {SignedExclusiveSwapPoolState} from "../../types/signedExclusiveSwapPoolState.sol";
import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

/// @title Signed Exclusive Swap Interface
/// @notice Extension that enforces forward-only swaps and applies signed, per-swap fee controls.
interface ISignedExclusiveSwap is IExposedStorage, ILocker, IForwardee, IExtension {
    /// @notice Emitted when a pool state is updated.
    event PoolStateUpdated(PoolId indexed poolId, SignedExclusiveSwapPoolState poolState);

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

    /// @notice Thrown when attempting to initialize a pool whose extension is not this contract.
    error PoolExtensionMustBeSelf();

    /// @notice Thrown when attempting to initialize pools directly through Core.
    error PoolInitializationDisabled();

    /// @notice Thrown when the signed minimum balance-update constraint is not met.
    error MinBalanceUpdateNotMet(PoolBalanceUpdate minBalanceUpdate, PoolBalanceUpdate actualBalanceUpdate);

    /// @notice Owner-only pool initialization for this extension.
    /// @param poolKey Pool configuration to initialize. Must point its extension to this contract.
    /// @param tick Initial tick for the pool.
    /// @param controller Initial pool controller with EOA marker encoded in its first bit.
    function initializePool(PoolKey memory poolKey, int32 tick, ControllerAddress controller)
        external
        returns (SqrtRatio sqrtRatio);

    /// @notice Public entrypoint to donate pending extension-collected fees to LPs.
    function accumulatePoolFees(PoolKey memory poolKey) external;

    /// @notice Sets a nonce bitmap word, allowing explicit nonce reuse/reset management.
    function setNonceBitmap(uint256 word, Bitmap bitmap) external;

    /// @notice Updates the controller for an existing pool.
    function setPoolController(PoolKey memory poolKey, ControllerAddress controller) external;
}
