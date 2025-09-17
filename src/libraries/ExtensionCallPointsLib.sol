// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IExtension} from "../interfaces/ICore.sol";

/// @dev Contains methods for determining whether an extension should be called
library ExtensionCallPointsLib {
    function shouldCallBeforeInitializePool(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(152, extension), 1)
        }
    }

    function shouldCallAfterInitializePool(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(159, extension), 1)
        }
    }

    function shouldCallBeforeSwap(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(158, extension), 1)
        }
    }

    function shouldCallAfterSwap(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(157, extension), 1)
        }
    }

    function shouldCallBeforeUpdatePosition(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(156, extension), 1)
        }
    }

    function shouldCallAfterUpdatePosition(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(155, extension), 1)
        }
    }

    function shouldCallBeforeCollectFees(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(154, extension), 1)
        }
    }

    function shouldCallAfterCollectFees(IExtension extension) internal pure returns (bool yes) {
        assembly ("memory-safe") {
            yes := and(shr(153, extension), 1)
        }
    }
}
