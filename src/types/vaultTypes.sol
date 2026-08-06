// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "./poolKey.sol";

/// @notice Represents a target allocation for a pool in the vault
/// @dev Used by strategies to define how vault assets should be distributed
struct PoolAllocation {
    /// @notice The pool key identifying the target pool
    PoolKey poolKey;
    /// @notice Target allocation in basis points (1 = 0.01%, 10000 = 100%)
    uint16 targetBps;
}
