// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {ITWAMM} from "../interfaces/extensions/ITWAMM.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";
import {OrderState} from "../types/orderState.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library TWAMMLib {
    using ExposedStorageLib for *;

    function poolState(ITWAMM twamm, bytes32 poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState = TwammPoolState.wrap(twamm.sload(poolId));
    }

    function orderState(ITWAMM twamm, address owner, bytes32 salt, bytes32 orderId)
        internal
        view
        returns (OrderState state)
    {
        bytes32 key;

        assembly ("memory-safe") {
            // order state
            mstore(0, owner)
            mstore(32, 4)

            mstore(32, keccak256(0, 64))
            mstore(0, salt)

            mstore(32, keccak256(0, 64))
            mstore(0, orderId)

            key := keccak256(0, 64)
        }

        state = OrderState.wrap(twamm.sload(key));
    }

    function rewardRateSnapshot(ITWAMM twamm, address owner, bytes32 salt, bytes32 orderId)
        internal
        view
        returns (uint256)
    {
        bytes32 key;

        assembly ("memory-safe") {
            // order state
            mstore(0, owner)
            mstore(32, 5)

            mstore(32, keccak256(0, 64))
            mstore(0, salt)

            mstore(32, keccak256(0, 64))
            mstore(0, orderId)

            key := keccak256(0, 64)
        }

        return uint256(twamm.sload(key));
    }
}
