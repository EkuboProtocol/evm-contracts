// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";
import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";

/// @title Boosted Fees Extension Interface
/// @notice Streams incentive amounts over configured windows and donates them as fees to pools.
/// @dev Configuration occurs via forwarded calls; hooks trigger accrual by locking the Core contract and accumulating fees.
interface IBoostedFees is IExposedStorage, IExtension, ILocker, IForwardee {
    /// @notice Emitted when a pool has incentives added
    /// @param poolId Identifier of the pool that is being incentivized
    /// @param startTime The first second that incentives will be paid out
    /// @param endTime The time at which incentives stop paying out
    /// @param rate0 Per-second incentive rate for token0 as a fixed point 96.32 value
    /// @param rate1 Per-second incentive rate for token1 as a fixed point 96.32 value
    event PoolBoosted(PoolId indexed poolId, uint64 startTime, uint64 endTime, uint128 rate0, uint128 rate1);

    /// @notice Reverts when provided times are invalid.
    error InvalidTimestamps();
    /// @notice Reverts when we try to update state for a pool that is not initialized.
    error PoolNotInitialized();
    /// @notice Reverts when incentive rates exceed permitted bounds.
    error MaxRateDeltaPerTime();

    /// @notice Public entrypoint to accrue and donate incentives for a pool.
    /// @param poolKey The pool key for which to donate incentives.
    function maybeAccumulateFees(PoolKey memory poolKey) external;
}
