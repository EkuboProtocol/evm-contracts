// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IExtension} from "../interfaces/ICore.sol";

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

    function shouldCallAfterInitializePool(IExtension extension, address initializer)
        internal
        pure
        returns (bool yes)
    {
        assembly ("memory-safe") {
            yes := and(shr(159, extension), iszero(eq(initializer, extension)))
        }
    }

    function shouldCallBeforeSwap(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(158, extension), iszero(eq(locker, extension)))
        }
    }

    function shouldCallAfterSwap(IExtension extension, address locker) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(157, extension), iszero(eq(locker, extension)))
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
