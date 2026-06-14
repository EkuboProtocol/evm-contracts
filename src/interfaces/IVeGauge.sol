// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";

interface IVeGauge {
    /// @notice Accounts fees sent by the ve positions contract for a pool.
    function notifyPoolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external;
}
