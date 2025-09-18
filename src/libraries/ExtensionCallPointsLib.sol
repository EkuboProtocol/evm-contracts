// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IExtension} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

/// @dev Contains methods for determining whether an extension should be called
library ExtensionCallPointsLib {
    function shouldCallBeforeInitializePool(IExtension extension, address initializer)
        internal
        pure
        returns (bool yes)
    {
        assembly ("memory-safe") {
            yes := and(shr(152, extension), iszero(eq(initializer, extension)))
        }
    }

    function maybeCallBeforeInitializePool(
        IExtension extension,
        address initializer,
        PoolKey memory poolKey,
        int32 tick
    ) internal {
        bool needCall = shouldCallBeforeInitializePool(extension, initializer);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "beforeInitializePool(address, (address, address, bytes32), int32)"
                mstore(freeMem, shl(224, 0x1fbbb462))
                mstore(add(freeMem, 4), initializer)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), tick)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 164, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallAfterInitializePool(IExtension extension, address initializer)
        internal
        pure
        returns (bool yes)
    {
        assembly ("memory-safe") {
            yes := and(shr(159, extension), iszero(eq(initializer, extension)))
        }
    }

    function maybeCallAfterInitializePool(
        IExtension extension,
        address initializer,
        PoolKey memory poolKey,
        int32 tick,
        SqrtRatio sqrtRatio
    ) internal {
        bool needCall = shouldCallAfterInitializePool(extension, initializer);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "afterInitializePool(address, (address, address, bytes32), int32, uint96)"
                mstore(freeMem, shl(224, 0x948374ff))
                mstore(add(freeMem, 4), initializer)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), tick)
                mstore(add(freeMem, 164), sqrtRatio)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 196, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallBeforeSwap(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(158, extension), iszero(eq(locker, extension)))
        }
    }

    function maybeCallBeforeSwap(
        IExtension extension,
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal {
        bool needCall = shouldCallBeforeSwap(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "beforeSwap(address, (address,address,bytes32), int128, bool, uint96, uint256)"
                mstore(freeMem, shl(224, 0x3c65c87a))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), amount)
                mstore(add(freeMem, 164), isToken1)
                mstore(add(freeMem, 196), sqrtRatioLimit)
                mstore(add(freeMem, 228), skipAhead)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 260, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallAfterSwap(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(157, extension), iszero(eq(locker, extension)))
        }
    }

    function maybeCallAfterSwap(
        IExtension extension,
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int128 delta0,
        int128 delta1
    ) internal {
        bool needCall = shouldCallAfterSwap(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "afterSwap(address, (address,address,bytes32), int128, bool, uint96, uint256, int128, int128)"
                mstore(freeMem, shl(224, 0xc0578abb))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), amount)
                mstore(add(freeMem, 164), isToken1)
                mstore(add(freeMem, 196), sqrtRatioLimit)
                mstore(add(freeMem, 228), skipAhead)
                mstore(add(freeMem, 260), delta0)
                mstore(add(freeMem, 292), delta1)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 324, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallBeforeUpdatePosition(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(156, extension), iszero(eq(locker, extension)))
        }
    }

    function shouldCallAfterUpdatePosition(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(155, extension), iszero(eq(locker, extension)))
        }
    }

    function shouldCallBeforeCollectFees(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(154, extension), iszero(eq(locker, extension)))
        }
    }

    function shouldCallAfterCollectFees(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(153, extension), iszero(eq(locker, extension)))
        }
    }
}
