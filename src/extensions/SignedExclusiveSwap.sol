// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, PoolKey, PositionId, CallPoints} from "../interfaces/ICore.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {ISignedExclusiveSwap, SignedSwapPayload} from "../interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {Bitmap} from "../types/bitmap.sol";
import {computeFee} from "../math/fee.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

function signedExclusiveSwapCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @notice Forward-only swap extension with controller-signed, per-swap fee customization.
/// @dev Extra fees are first collected into extension saved balances, then donated to LPs at the start of the next block.
contract SignedExclusiveSwap is ISignedExclusiveSwap, BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;
    using ExposedStorageLib for *;

    bytes32 internal constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant _SIGNED_SWAP_TYPEHASH = keccak256(
        "SignedSwap(address token0,address token1,bytes32 config,bytes32 params,address authorizedLocker,uint64 deadline,uint64 extraFee,uint256 nonce)"
    );
    bytes32 internal constant _NAME_HASH = keccak256("Ekubo SignedExclusiveSwap");
    bytes32 internal constant _VERSION_HASH = keccak256("1");

    address public immutable CONTROLLER;

    mapping(PoolId poolId => uint32 lastUpdateTime) internal _poolLastUpdateTime;
    mapping(uint256 => Bitmap) public nonceBitmap;

    constructor(ICore core, address controller) BaseExtension(core) BaseForwardee(core) {
        CONTROLLER = controller;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return signedExclusiveSwapCallPoints();
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
        if (_poolLastUpdateTime[poolId] != uint32(block.timestamp)) {
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

        _poolLastUpdateTime[poolId] = uint32(block.timestamp);
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        SignedSwapPayload memory payload = abi.decode(data, (SignedSwapPayload));

        if (block.timestamp > payload.deadline) revert SignatureExpired();
        if (payload.authorizedLocker != address(0) && payload.authorizedLocker != original.addr()) {
            revert UnauthorizedLocker();
        }

        _consumeNonce(payload.nonce);

        bytes32 digest = _hashTypedData(payload);
        if (!SignatureCheckerLib.isValidSignatureNow(CONTROLLER, digest, payload.signature)) {
            revert InvalidSignature();
        }

        accumulatePoolFees(payload.poolKey);

        SwapParameters params = payload.params.withDefaultSqrtRatioLimit();

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = CORE.swap(0, payload.poolKey, params);

        int256 saveDelta0;
        int256 saveDelta1;

        if (payload.extraFee != 0) {
            if (params.isExactOut()) {
                if (balanceUpdate.delta0() > 0) {
                    int128 fee = SafeCastLib.toInt128(
                        computeFee(uint128(uint256(int256(balanceUpdate.delta0()))), payload.extraFee)
                    );
                    saveDelta0 += fee;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + fee, balanceUpdate.delta1());
                } else if (balanceUpdate.delta1() > 0) {
                    int128 fee = SafeCastLib.toInt128(
                        computeFee(uint128(uint256(int256(balanceUpdate.delta1()))), payload.extraFee)
                    );
                    saveDelta1 += fee;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + fee);
                }
            } else {
                if (balanceUpdate.delta0() < 0) {
                    int128 fee = SafeCastLib.toInt128(
                        computeFee(uint128(uint256(-int256(balanceUpdate.delta0()))), payload.extraFee)
                    );
                    saveDelta0 += fee;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + fee, balanceUpdate.delta1());
                } else if (balanceUpdate.delta1() < 0) {
                    int128 fee = SafeCastLib.toInt128(
                        computeFee(uint128(uint256(-int256(balanceUpdate.delta1()))), payload.extraFee)
                    );
                    saveDelta1 += fee;
                    balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + fee);
                }
            }
        }

        if (saveDelta0 != 0 || saveDelta1 != 0) {
            CORE.updateSavedBalances(
                payload.poolKey.token0,
                payload.poolKey.token1,
                PoolId.unwrap(payload.poolKey.toPoolId()),
                saveDelta0,
                saveDelta1
            );
        }

        result = abi.encode(balanceUpdate, stateAfter);
    }

    function _hashTypedData(SignedSwapPayload memory payload) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNED_SWAP_TYPEHASH,
                payload.poolKey.token0,
                payload.poolKey.token1,
                PoolConfig.unwrap(payload.poolKey.config),
                SwapParameters.unwrap(payload.params),
                payload.authorizedLocker,
                payload.deadline,
                payload.extraFee,
                payload.nonce
            )
        );

        bytes32 domainSeparator =
            keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));

        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _consumeNonce(uint256 nonce) internal {
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
}
