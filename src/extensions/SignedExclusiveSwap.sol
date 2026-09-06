// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, PoolKey, CallPoints} from "../interfaces/ICore.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {ISignedExclusiveSwap} from "../interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {SignedExclusiveSwapLib} from "../libraries/SignedExclusiveSwapLib.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {SignedSwapMeta} from "../types/signedSwapMeta.sol";
import {ControllerAddress} from "../types/controllerAddress.sol";
import {Locker} from "../types/locker.sol";
import {Bitmap} from "../types/bitmap.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {Ownable} from "solady/auth/Ownable.sol";

function signedExclusiveSwapCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Forward-only swap extension with controller-signed, per-swap fee customization.
/// @dev The signed fee is passed to `Core.swap` as an additional fee, so it is charged on the input
/// token and accrues to the pool's liquidity providers exactly like a pool fee would.
contract SignedExclusiveSwap is ISignedExclusiveSwap, BaseExtension, BaseForwardee, ExposedStorage, Ownable {
    using CoreLib for *;
    using ExposedStorageLib for *;
    using SignedExclusiveSwapLib for *;

    /// @dev Cached for performance
    bytes32 private immutable _DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    uint32 internal constant _MAX_DEADLINE_FUTURE_WINDOW = 30 days;

    mapping(uint256 => Bitmap) public nonceBitmap;

    constructor(ICore core, address owner) BaseExtension(core) BaseForwardee(core) {
        _initializeOwner(owner);
        _DOMAIN_SEPARATOR = this.computeDomainSeparatorHash();
        _CACHED_CHAIN_ID = block.chainid;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return signedExclusiveSwapCallPoints();
    }

    /// @inheritdoc ISignedExclusiveSwap
    function initializePool(PoolKey memory poolKey, int32 tick, ControllerAddress controller)
        external
        onlyOwner
        returns (SqrtRatio sqrtRatio)
    {
        if (poolKey.config.extension() != address(this)) revert PoolExtensionMustBeSelf();
        // the signed fee is the whole fee, so the pool must not charge one of its own
        if (poolKey.config.fee() != 0) revert PoolFeeMustBeZero();
        _validateController(controller);

        sqrtRatio = CORE.initializePool(poolKey, tick);
        _setController({poolId: poolKey.toPoolId(), controller: controller});
    }

    /// @inheritdoc IExtension
    function beforeInitializePool(address, PoolKey calldata, int32)
        external
        view
        override(BaseExtension, IExtension)
        onlyCore
    {
        revert PoolInitializationDisabled();
    }

    /// @notice We only allow swapping via forward to this extension.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension, IExtension) {
        revert SwapMustHappenThroughForward();
    }

    /// @inheritdoc ISignedExclusiveSwap
    function setNonceBitmap(uint256 word, Bitmap bitmap) external onlyOwner {
        nonceBitmap[word] = bitmap;
    }

    /// @inheritdoc ISignedExclusiveSwap
    function setPoolController(PoolKey memory poolKey, ControllerAddress controller) external onlyOwner {
        if (poolKey.config.extension() != address(this) || !CORE.poolState(poolKey.toPoolId()).isInitialized()) {
            revert ICore.PoolNotInitialized();
        }
        _validateController(controller);

        _setController({poolId: poolKey.toPoolId(), controller: controller});
    }

    /// @inheritdoc ISignedExclusiveSwap
    function broadcastSignedSwaps(SignedSwapBroadcast[] calldata signedSwaps) external {
        uint32 currentTimestamp = uint32(block.timestamp);
        for (uint256 i; i < signedSwaps.length;) {
            SignedSwapBroadcast calldata signedSwap = signedSwaps[i];
            _validateMetaForUse(signedSwap.meta, currentTimestamp);
            _validateNonceAvailable(signedSwap.meta.nonce());
            _validateSignature(signedSwap.poolId, signedSwap.meta, signedSwap.minBalanceUpdate, signedSwap.signature);

            emit SignedSwapBroadcasted(
                signedSwap.poolId, signedSwap.meta, signedSwap.minBalanceUpdate, signedSwap.signature
            );

            unchecked {
                ++i;
            }
        }
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        (
            PoolKey memory poolKey,
            SwapParameters params,
            SignedSwapMeta meta,
            PoolBalanceUpdate minBalanceUpdate,
            bytes memory signature
        ) = abi.decode(data, (PoolKey, SwapParameters, SignedSwapMeta, PoolBalanceUpdate, bytes));

        _validateMetaForUse(meta, uint32(block.timestamp));
        if (!meta.isAuthorized(original)) revert UnauthorizedLocker();

        PoolId poolId = poolKey.toPoolId();
        _validateSignature(poolId, meta, minBalanceUpdate, signature);

        // the signed fee is a 0.32 number, and Core takes a 0.64 number
        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
            CORE.swap(0, poolKey, params, uint64(meta.fee()) << 32);

        if (balanceUpdate.delta0() < minBalanceUpdate.delta0() || balanceUpdate.delta1() < minBalanceUpdate.delta1()) {
            revert MinBalanceUpdateNotMet(minBalanceUpdate, balanceUpdate);
        }

        // only now that all validation has succeeded, consume the nonce,
        // which reduces the gas cost in the case of swaps exceeding the allowed amount
        _consumeNonce(meta.nonce());

        result = abi.encode(balanceUpdate, stateAfter);
    }

    function _validateSignature(
        PoolId poolId,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate,
        bytes memory signature
    ) internal view {
        if (!_getController(poolId)
                .isSignatureValid(
                    SignedExclusiveSwapLib.hashSignedSwapPayload(_domainSeparator(), poolId, meta, minBalanceUpdate),
                    signature
                )) {
            revert InvalidSignature();
        }
    }

    function _domainSeparator() internal view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _DOMAIN_SEPARATOR;
        return this.computeDomainSeparatorHash();
    }

    function _validateController(ControllerAddress controller) internal view {
        address controllerAddress = ControllerAddress.unwrap(controller);
        if (controllerAddress == address(0)) revert InvalidController();
        if (controller.isEoa()) {
            if (controllerAddress.code.length != 0) revert InvalidController();
        } else if (controllerAddress.code.length == 0) {
            revert InvalidController();
        }
    }

    function _validateMetaForUse(SignedSwapMeta meta, uint32 currentTimestamp) internal pure {
        if (meta.isExpired(currentTimestamp)) revert SignatureExpired();
        unchecked {
            if ((meta.deadline() - currentTimestamp) > _MAX_DEADLINE_FUTURE_WINDOW) revert DeadlineTooFar();
        }
    }

    function _validateNonceAvailable(uint64 nonce) internal view {
        if (nonce == type(uint64).max) return;

        uint256 word = nonce >> 8;
        uint8 bit = uint8(nonce & 0xff);
        if (nonceBitmap[word].isSet(bit)) revert NonceAlreadyUsed();
    }

    function _consumeNonce(uint64 nonce) internal {
        // max nonce is reserved as a reusable sentinel and is never consumed
        if (nonce == type(uint64).max) return;

        uint256 word = nonce >> 8;
        uint8 bit = uint8(nonce & 0xff);

        Bitmap current = nonceBitmap[word];
        Bitmap next = current.toggle(bit);

        if (Bitmap.unwrap(next) < Bitmap.unwrap(current)) revert NonceAlreadyUsed();
        nonceBitmap[word] = next;
    }

    function _getController(PoolId poolId) internal view returns (ControllerAddress controller) {
        assembly ("memory-safe") {
            controller := sload(poolId)
        }
    }

    function _setController(PoolId poolId, ControllerAddress controller) internal {
        assembly ("memory-safe") {
            sstore(poolId, controller)
        }
        emit PoolControllerUpdated(poolId, controller);
    }
}
