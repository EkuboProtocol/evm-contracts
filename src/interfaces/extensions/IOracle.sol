// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {PoolKey} from "../../types/poolKey.sol";

/// @title Oracle Interface
/// @notice Interface for the Ekubo Oracle Extension
/// @dev Records price and liquidity into accumulators enabling a separate contract to compute a manipulation resistant average price and liquidity
interface IOracle {
    /// @notice Snapshot data structure containing price and liquidity accumulator values
    /// @dev Stores cumulative values for computing time-weighted averages
    struct Snapshot {
        /// @notice The truncated least significant 32 bits of the timestamp when this snapshot was written
        uint32 timestamp;
        /// @notice Can be used to compute harmonic mean liquidity over a period of time, in order to determine the safety of the oracle
        uint160 secondsPerLiquidityCumulative;
        /// @notice Can be used to compute a time weighted average tick over a period of time
        int64 tickCumulative;
    }

    /// @notice Counts and metadata for snapshots of a token
    /// @dev Tracks the circular buffer state for snapshots
    struct Counts {
        /// @notice The index of the last snapshot that was written
        uint32 index;
        /// @notice The number of snapshots that have been written for the pool
        uint32 count;
        /// @notice The maximum number of snapshots that will be stored for the token
        uint32 capacity;
        /// @notice The timestamp of the last snapshot that was written
        uint32 lastTimestamp;
    }

    /// @notice Observation data structure for extrapolated snapshot values
    /// @dev Contains cumulative values at a specific point in time
    struct Observation {
        /// @notice Cumulative seconds per liquidity at the observation time
        uint160 secondsPerLiquidityCumulative;
        /// @notice Cumulative tick value at the observation time
        int64 tickCumulative;
    }

    /// @notice Thrown when trying to create a pool that doesn't pair with the native token
    error PairsWithNativeTokenOnly();

    /// @notice Thrown when the pool fee is not zero
    error FeeMustBeZero();

    /// @notice Thrown when the tick spacing is not the maximum allowed value
    error TickSpacingMustBeMaximum();

    /// @notice Thrown when querying data for a future timestamp
    error FutureTime();

    /// @notice Thrown when no previous snapshot exists for the given time
    /// @param token The token address
    /// @param time The requested timestamp
    error NoPreviousSnapshotExists(address token, uint256 time);

    /// @notice Thrown when the end time is less than the start time
    error EndTimeLessThanStartTime();

    /// @notice Thrown when timestamps are not provided in sorted order
    error TimestampsNotSorted();

    /// @notice Thrown when zero timestamps are provided to a function that requires at least one
    error ZeroTimestampsProvided();

    /// @notice Gets the counts and metadata for snapshots of a token
    /// @param token The token address
    /// @return index The index of the last snapshot that was written
    /// @return count The number of snapshots that have been written for the pool
    /// @return capacity The maximum number of snapshots that will be stored for the token
    /// @return lastTimestamp The timestamp of the last snapshot that was written
    function counts(address token)
        external
        view
        returns (uint32 index, uint32 count, uint32 capacity, uint32 lastTimestamp);

    /// @notice Gets a specific snapshot for a token at a given index
    /// @param token The token address
    /// @param index The snapshot index
    /// @return timestamp The truncated least significant 32 bits of the timestamp when this snapshot was written
    /// @return secondsPerLiquidityCumulative Can be used to compute harmonic mean liquidity over a period of time
    /// @return tickCumulative Can be used to compute a time weighted average tick over a period of time
    function snapshots(address token, uint256 index)
        external
        view
        returns (uint32 timestamp, uint160 secondsPerLiquidityCumulative, int64 tickCumulative);

    /// @notice Gets the pool key for the given token
    /// @dev The only allowed pool key for the given token pairs with the native token
    /// @param token The token address
    /// @return The pool key for the token paired with native token
    function getPoolKey(address token) external view returns (PoolKey memory);

    /// @notice Expands the capacity of the list of snapshots for the given token
    /// @param token The token address
    /// @param minCapacity The minimum capacity required
    /// @return capacity The actual capacity after expansion
    function expandCapacity(address token, uint32 minCapacity) external returns (uint32 capacity);

    /// @notice Finds the snapshot with the greatest timestamp ≤ the given time
    /// @param token The token address
    /// @param time The target timestamp
    /// @return count The total number of snapshots for the token
    /// @return logicalIndex The logical index of the found snapshot
    /// @return snapshot The snapshot data
    function findPreviousSnapshot(address token, uint256 time)
        external
        view
        returns (uint256 count, uint256 logicalIndex, Snapshot memory snapshot);

    /// @notice Returns cumulative snapshot values at a specific time
    /// @dev Extrapolates values from the most recent snapshot before the given time
    /// @param token The token address
    /// @param atTime The target timestamp
    /// @return secondsPerLiquidityCumulative The cumulative seconds per liquidity at the target time
    /// @return tickCumulative The cumulative tick value at the target time
    function extrapolateSnapshot(address token, uint256 atTime)
        external
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative);

    /// @notice Returns extrapolated snapshots at each of the provided sorted timestamps
    /// @dev Efficiently computes observations for multiple timestamps in a single call
    /// @param token The token address
    /// @param timestamps Array of timestamps in ascending order
    /// @return observations Array of observations corresponding to each timestamp
    function getExtrapolatedSnapshotsForSortedTimestamps(address token, uint256[] memory timestamps)
        external
        view
        returns (Observation[] memory observations);
}
