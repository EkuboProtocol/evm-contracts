// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, PoolKey, PositionId, CallPoints} from "../interfaces/ICore.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {ISignedExclusiveSwap} from "../interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {SignedExclusiveSwapLib} from "../libraries/SignedExclusiveSwapLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {SignedSwapMeta} from "../types/signedSwapMeta.sol";
import {
    SignedExclusiveSwapPoolState,
    createSignedExclusiveSwapPoolState
} from "../types/signedExclusiveSwapPoolState.sol";
import {Locker} from "../types/locker.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {Bitmap} from "../types/bitmap.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {computeFee} from "../math/fee.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

function signedExclusiveSwapCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: true,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @notice Forward-only swap extension with controller-signed, per-swap fee customization.
/// @dev Fees are first collected into extension saved balances, then donated to LPs at the start of the next block.
contract SignedExclusiveSwap is ISignedExclusiveSwap, BaseExtension, BaseForwardee, ExposedStorage, Ownable {
    using CoreLib for *;
    using ExposedStorageLib for *;
    using SignedExclusiveSwapLib for *;
    using ECDSA for bytes32;

    address public defaultController;
    bool public defaultControllerIsEoa;

    mapping(uint256 => Bitmap) public nonceBitmap;

    constructor(ICore core, address owner, address _defaultController, bool _defaultControllerIsEoa)
        BaseExtension(core)
        BaseForwardee(core)
    {
        _initializeOwner(owner);
        defaultController = _defaultController;
        defaultControllerIsEoa = _defaultControllerIsEoa;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return signedExclusiveSwapCallPoints();
    }

    /// @inheritdoc IExtension
    function afterInitializePool(address, PoolKey memory poolKey, int32, SqrtRatio)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (poolKey.config.fee() != 0) revert PoolFeeMustBeZero();

        PoolId poolId = poolKey.toPoolId();
        _setPoolState(
            poolId,
            createSignedExclusiveSwapPoolState(defaultController, uint32(block.timestamp), defaultControllerIsEoa)
        );

        emit PoolControllerUpdated(poolId, defaultController, defaultControllerIsEoa);
    }

    /// @notice We only allow swapping via forward to this extension.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension, IExtension) {
        revert SwapMustHappenThroughForward();
    }

    /// @dev Prevents new liquidity from collecting extension fees that should belong to existing LPs.
    function beforeUpdatePosition(Locker, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
    {
        accumulatePoolFees(poolKey);
    }

    /// @dev Allows fee collection to observe extension donations up to the start of the current block.
    function beforeCollectFees(Locker, PoolKey memory poolKey, PositionId)
        external
        override(BaseExtension, IExtension)
    {
        accumulatePoolFees(poolKey);
    }

    /// @inheritdoc ISignedExclusiveSwap
    function accumulatePoolFees(PoolKey memory poolKey) public {
        PoolId poolId = poolKey.toPoolId();
        if (_getPoolState(poolId).lastUpdateTime() != uint32(block.timestamp)) {
            address target = address(CORE);
            assembly ("memory-safe") {
                let o := mload(0x40)
                mstore(o, shl(224, 0xf83d08ba))
                mcopy(add(o, 4), poolKey, 96)

                if iszero(call(gas(), target, 0, o, 100, 0, 0)) {
                    returndatacopy(o, 0, returndatasize())
                    revert(o, returndatasize())
                }
            }
        }
    }

    /// @dev Core lock callback used by `accumulatePoolFees`.
    function locked_6416899205(uint256) external onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            calldatacopy(poolKey, 36, 96)
        }

        PoolId poolId = poolKey.toPoolId();
        (uint128 fees0, uint128 fees1) = _loadSavedFees(poolId, poolKey.token0, poolKey.token1);

        if (fees0 != 0 || fees1 != 0) {
            CORE.accumulateAsFees(poolKey, fees0, fees1);
            CORE.updateSavedBalances(
                poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), -int256(uint256(fees0)), -int256(uint256(fees1))
            );
        }

        _setPoolState(poolId, _getPoolState(poolId).withLastUpdateTime(uint32(block.timestamp)));
    }

    /// @inheritdoc ISignedExclusiveSwap
    function setDefaultController(address controller, bool isEoa) external onlyOwner {
        defaultController = controller;
        defaultControllerIsEoa = isEoa;

        emit DefaultControllerUpdated(controller, isEoa);
    }

    /// @inheritdoc ISignedExclusiveSwap
    function setNonceBitmap(uint256 word, Bitmap bitmap) external onlyOwner {
        nonceBitmap[word] = bitmap;
    }

    /// @inheritdoc ISignedExclusiveSwap
    function setPoolController(PoolKey memory poolKey, address controller, bool isEoa) external onlyOwner {
        if (poolKey.config.extension() != address(this) || !CORE.poolState(poolKey.toPoolId()).isInitialized()) {
            revert ICore.PoolNotInitialized();
        }

        PoolId poolId = poolKey.toPoolId();
        _setPoolState(poolId, _getPoolState(poolId).withController(controller, isEoa));

        emit PoolControllerUpdated(poolId, controller, isEoa);
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        (
            PoolKey memory poolKey,
            SwapParameters params,
            SignedSwapMeta meta,
            PoolBalanceUpdate minBalanceUpdate,
            bytes memory signature
        ) = abi.decode(data, (PoolKey, SwapParameters, SignedSwapMeta, PoolBalanceUpdate, bytes));
        PoolId poolId = poolKey.toPoolId();
        SignedExclusiveSwapPoolState state = _getPoolState(poolId);

        if (meta.isExpired(uint32(block.timestamp))) revert SignatureExpired();

        if (!meta.isAuthorized(original)) {
            revert UnauthorizedLocker();
        }

        _consumeNonce(meta.nonce());

        bytes32 digest = this.hashSignedSwapPayload(poolId, meta, minBalanceUpdate);
        if (!_isValidControllerSignature(state.controller(), state.controllerIsEoa(), digest, signature)) {
            revert InvalidSignature();
        }

        accumulatePoolFees(poolKey);
        params = params.withDefaultSqrtRatioLimit();

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = CORE.swap(0, poolKey, params);

        int256 saveDelta0;
        int256 saveDelta1;
        uint64 metaFeeX64 = uint64(meta.fee()) << 32;

        if (metaFeeX64 != 0) {
            if (params.isExactOut()) {
                if (balanceUpdate.delta0() > 0) {
                    int128 feeAmount =
                        SafeCastLib.toInt128(computeFee(uint128(uint256(int256(balanceUpdate.delta0()))), metaFeeX64));
                    saveDelta0 += feeAmount;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + feeAmount, balanceUpdate.delta1());
                } else if (balanceUpdate.delta1() > 0) {
                    int128 feeAmount =
                        SafeCastLib.toInt128(computeFee(uint128(uint256(int256(balanceUpdate.delta1()))), metaFeeX64));
                    saveDelta1 += feeAmount;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + feeAmount);
                }
            } else {
                if (balanceUpdate.delta0() < 0) {
                    int128 feeAmount =
                        SafeCastLib.toInt128(computeFee(uint128(uint256(-int256(balanceUpdate.delta0()))), metaFeeX64));
                    saveDelta0 += feeAmount;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + feeAmount, balanceUpdate.delta1());
                } else if (balanceUpdate.delta1() < 0) {
                    int128 feeAmount =
                        SafeCastLib.toInt128(computeFee(uint128(uint256(-int256(balanceUpdate.delta1()))), metaFeeX64));
                    saveDelta1 += feeAmount;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + feeAmount);
                }
            }
        }

        if (saveDelta0 != 0 || saveDelta1 != 0) {
            CORE.updateSavedBalances(poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), saveDelta0, saveDelta1);
        }

        _validateMinBalanceUpdate(minBalanceUpdate, balanceUpdate);

        result = abi.encode(balanceUpdate, stateAfter);
    }

    function _validateMinBalanceUpdate(PoolBalanceUpdate minBalanceUpdate, PoolBalanceUpdate actualBalanceUpdate)
        internal
        pure
    {
        if (
            actualBalanceUpdate.delta0() < minBalanceUpdate.delta0()
                || actualBalanceUpdate.delta1() < minBalanceUpdate.delta1()
        ) {
            revert MinBalanceUpdateNotMet(minBalanceUpdate, actualBalanceUpdate);
        }
    }

    function _consumeNonce(uint32 nonce) internal {
        uint256 word = nonce >> 8;
        uint8 bit = uint8(nonce & 0xff);

        Bitmap current = nonceBitmap[word];
        if (current.isSet(bit)) revert NonceAlreadyUsed();
        nonceBitmap[word] = current.toggle(bit);
    }

    function _loadSavedFees(PoolId poolId, address token0, address token1)
        internal
        view
        returns (uint128 fees0, uint128 fees1)
    {
        StorageSlot feesSlot = CoreStorageLayout.savedBalancesSlot(address(this), token0, token1, PoolId.unwrap(poolId));
        bytes32 value = CORE.sload(feesSlot);

        assembly ("memory-safe") {
            fees0 := shr(128, value)
            fees0 := sub(fees0, gt(fees0, 0))

            fees1 := shr(128, shl(128, value))
            fees1 := sub(fees1, gt(fees1, 0))
        }
    }

    function _isValidControllerSignature(address controller, bool isEoa, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool valid)
    {
        if (isEoa) {
            return digest.recover(signature) == controller;
        }
        return SignatureCheckerLib.isValidSignatureNow(controller, digest, signature);
    }

    function _getPoolState(PoolId poolId) internal view returns (SignedExclusiveSwapPoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function _setPoolState(PoolId poolId, SignedExclusiveSwapPoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }
}
