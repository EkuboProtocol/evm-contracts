// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {IExtension} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolState} from "../types/poolState.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";

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

    function shouldCallAfterInitializePool(IExtension extension, address initializer) internal pure returns (bool yes) {
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

    function shouldCallBeforeSwap(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(158, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallBeforeSwap(IExtension extension, Locker locker, PoolKey memory poolKey, SwapParameters params)
        internal
    {
        bool needCall = shouldCallBeforeSwap(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "beforeSwap(bytes32,(address,address,bytes32),bytes32)"
                mstore(freeMem, shl(224, 0xca11dba7))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), params)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 164, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallAfterSwap(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(157, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallAfterSwap(
        IExtension extension,
        Locker locker,
        PoolKey memory poolKey,
        SwapParameters params,
        PoolBalanceUpdate balanceUpdate,
        PoolState stateAfter
    ) internal {
        bool needCall = shouldCallAfterSwap(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "afterSwap(bytes32,(address,address,bytes32),bytes32,bytes32,bytes32)"
                mstore(freeMem, shl(224, 0xa4e8f288))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), params)
                mstore(add(freeMem, 164), balanceUpdate)
                mstore(add(freeMem, 196), stateAfter)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 228, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallBeforeUpdatePosition(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(156, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallBeforeUpdatePosition(
        IExtension extension,
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        int128 liquidityDelta
    ) internal {
        bool needCall = shouldCallBeforeUpdatePosition(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "beforeUpdatePosition(bytes32, (address,address,bytes32), bytes32, int128)"
                mstore(freeMem, shl(224, 0x0035c723))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), positionId)
                mstore(add(freeMem, 164), liquidityDelta)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 196, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallAfterUpdatePosition(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(155, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallAfterUpdatePosition(
        IExtension extension,
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        int128 liquidityDelta,
        PoolBalanceUpdate balanceUpdate,
        PoolState stateAfter
    ) internal {
        bool needCall = shouldCallAfterUpdatePosition(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "afterUpdatePosition(bytes32,(address,address,bytes32),bytes32,int128,bytes32,bytes32)"
                mstore(freeMem, shl(224, 0x25fa4e69))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), positionId)
                mstore(add(freeMem, 164), liquidityDelta)
                mstore(add(freeMem, 196), balanceUpdate)
                mstore(add(freeMem, 228), stateAfter)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 260, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallBeforeCollectFees(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(154, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallBeforeCollectFees(
        IExtension extension,
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId
    ) internal {
        bool needCall = shouldCallBeforeCollectFees(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "beforeCollectFees(bytes32, (address,address,bytes32), bytes32)"
                mstore(freeMem, shl(224, 0xdf65d8d1))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), positionId)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 164, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }

    function shouldCallAfterCollectFees(IExtension extension, Locker locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(153, extension), iszero(eq(shl(96, locker), shl(96, extension))))
        }
    }

    function maybeCallAfterCollectFees(
        IExtension extension,
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        uint128 amount0,
        uint128 amount1
    ) internal {
        bool needCall = shouldCallAfterCollectFees(extension, locker);
        assembly ("memory-safe") {
            if needCall {
                let freeMem := mload(0x40)
                // cast sig "afterCollectFees(bytes32, (address,address,bytes32), bytes32, uint128, uint128)"
                mstore(freeMem, shl(224, 0x751fd5df))
                mstore(add(freeMem, 4), locker)
                mcopy(add(freeMem, 36), poolKey, 96)
                mstore(add(freeMem, 132), positionId)
                mstore(add(freeMem, 164), amount0)
                mstore(add(freeMem, 196), amount1)
                // bubbles up the revert
                if iszero(call(gas(), extension, 0, freeMem, 228, 0, 0)) {
                    returndatacopy(freeMem, 0, returndatasize())
                    revert(freeMem, returndatasize())
                }
            }
        }
    }
}
