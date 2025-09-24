// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ITWAMM} from "../interfaces/extensions/ITWAMM.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";
import {OrderState} from "../types/orderState.sol";
import {PoolId} from "../types/poolId.sol";
import {TWAMMStorageLayout} from "./TWAMMStorageLayout.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library TWAMMLib {
    using ExposedStorageLib for *;

    function poolState(ITWAMM twamm, PoolId poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState = TwammPoolState.wrap(twamm.sload(PoolId.unwrap(poolId)));
    }

    function orderState(ITWAMM twamm, address owner, bytes32 salt, bytes32 orderId)
        internal
        view
        returns (OrderState state)
    {
        state = OrderState.wrap(twamm.sload(TWAMMStorageLayout.orderStateSlot(owner, salt, orderId)));
    }

    function rewardRateSnapshot(ITWAMM twamm, address owner, bytes32 salt, bytes32 orderId)
        internal
        view
        returns (uint256)
    {
        return uint256(twamm.sload(TWAMMStorageLayout.orderRewardRateSnapshotSlot(owner, salt, orderId)));
    }
}
