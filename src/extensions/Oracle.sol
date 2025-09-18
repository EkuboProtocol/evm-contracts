// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, Config} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IOracle} from "../interfaces/extensions/IOracle.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Returns the call points configuration for the Oracle extension
/// @dev Specifies which hooks the Oracle needs to capture price and liquidity data
/// @return The call points configuration for Oracle functionality
function oracleCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Converts a logical index to a storage index for circular snapshot array
/// @dev Because the snapshots array is circular, the storage index of the most recently written snapshot can be any value in [0,c.count).
///      To simplify the code, we operate on the logical indices, rather than the storage indices.
///      For logical indices, the most recently written value is always at logicalIndex = c.count-1 and the earliest snapshot is always at logicalIndex = 0.
/// @param index The index of the most recently written snapshot
/// @param count The total number of snapshots that have been written
/// @param logicalIndex The index of the snapshot for which to compute the storage index
/// @return The storage index corresponding to the logical index
function logicalIndexToStorageIndex(uint256 index, uint256 count, uint256 logicalIndex) pure returns (uint256) {
    // We assume index < count and logicalIndex < count
    unchecked {
        return (index + 1 + logicalIndex) % count;
    }
}

/// @title Ekubo Oracle Extension
/// @author Moody Salem <moody@ekubo.org>
/// @notice Records price and liquidity into accumulators enabling a separate contract to compute a manipulation resistant average price and liquidity
contract Oracle is ExposedStorage, BaseExtension, IOracle {
    using CoreLib for ICore;

    mapping(address token => Counts) public counts;
    mapping(address token => mapping(uint256 index => Snapshot snapshot)) public snapshots;

    constructor(ICore core) BaseExtension(core) {}

    /// @notice Emits a snapshot event for off-chain indexing
    /// @dev Uses assembly for gas-efficient event emission
    /// @param token The token address for the snapshot
    /// @param encodedSnapshot The encoded snapshot data
    function _emitSnapshotEvent(address token, bytes32 encodedSnapshot) private {
        unchecked {
            assembly ("memory-safe") {
                mstore(0, shl(96, token))
                mstore(20, encodedSnapshot)
                log0(0, 52)
            }
        }
    }

    /// @inheritdoc IOracle
    function getPoolKey(address token) public view returns (PoolKey memory) {
        Config config;
        assembly ("memory-safe") {
            config := shl(96, address())
        }
        return PoolKey({token0: NATIVE_TOKEN_ADDRESS, token1: token, config: config});
    }

    /// @notice Returns the call points configuration for this extension
    /// @dev Overrides the base implementation to return Oracle-specific call points
    /// @return The call points configuration
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return oracleCallPoints();
    }

    /// @notice Inserts a new snapshot if enough time has passed since the last one
    /// @dev Only inserts if block.timestamp > lastTimestamp to avoid duplicate snapshots
    /// @param poolId The unique identifier for the pool
    /// @param token The token address for the oracle data
    function maybeInsertSnapshot(bytes32 poolId, address token) private {
        unchecked {
            bytes32 countsSlot;

            uint256 index;
            uint256 count;
            uint256 capacity;

            uint32 lastTimestamp;

            assembly ("memory-safe") {
                mstore(0, token)
                mstore(32, 0)
                countsSlot := keccak256(0, 64)

                let packed := sload(countsSlot)
                index := and(packed, 0xffffffff)
                count := and(shr(32, packed), 0xffffffff)
                capacity := and(shr(64, packed), 0xffffffff)
                lastTimestamp := and(shr(96, packed), 0xffffffff)
            }

            uint32 timePassed = uint32(block.timestamp) - lastTimestamp;
            if (timePassed == 0) return;

            // we know count is always g.t. 0 in the places this is called
            Snapshot memory last = snapshots[token][index];

            (, int32 tick, uint128 liquidity) = CORE.poolState(poolId);

            Snapshot memory snapshot = Snapshot({
                timestamp: uint32(block.timestamp),
                secondsPerLiquidityCumulative: last.secondsPerLiquidityCumulative
                    + ((uint160(timePassed) << 128) / uint160(FixedPointMathLib.max(1, liquidity))),
                tickCumulative: last.tickCumulative + int64(uint64(timePassed)) * tick
            });

            bytes32 encodedSnapshot;

            assembly ("memory-safe") {
                let isLastIndex := eq(index, sub(count, 1))
                let incrementCount := and(isLastIndex, gt(capacity, count))

                count := add(count, incrementCount)
                index := mod(add(index, 1), count)
                lastTimestamp := and(timestamp(), 0xffffffff)

                // capacity, count and index are all only set/modified from assembly so we know there is no dirty upper bits
                sstore(countsSlot, or(shl(96, lastTimestamp), or(or(shl(64, capacity), shl(32, count)), index)))

                encodedSnapshot :=
                    or(or(lastTimestamp, shl(32, mload(add(snapshot, 32)))), shl(192, mload(add(snapshot, 64))))

                mstore(0, token)
                mstore(32, 1)
                mstore(32, keccak256(0, 64))
                mstore(0, index)

                sstore(keccak256(0, 64), encodedSnapshot)
            }

            _emitSnapshotEvent(token, encodedSnapshot);
        }
    }

    /// @notice Called before a pool is initialized to set up Oracle tracking
    /// @dev Validates pool configuration and initializes the first snapshot
    function beforeInitializePool(address, PoolKey calldata key, int32) external override onlyCore {
        if (key.token0 != NATIVE_TOKEN_ADDRESS) revert PairsWithNativeTokenOnly();
        if (key.fee() != 0) revert FeeMustBeZero();
        if (key.tickSpacing() != FULL_RANGE_ONLY_TICK_SPACING) revert TickSpacingMustBeMaximum();

        address token = key.token1;

        // in case expandCapacity is called before the pool is initialized:
        //  remember we have the capacity since the snapshot storage has been initialized
        uint32 lastTimestamp = uint32(block.timestamp);
        counts[token] = Counts({
            index: 0,
            count: 1,
            capacity: uint32(FixedPointMathLib.max(1, counts[token].capacity)),
            lastTimestamp: lastTimestamp
        });
        Snapshot memory snapshot = Snapshot(lastTimestamp, 0, 0);
        snapshots[token][0] = snapshot;

        bytes32 encodedSnapshot = bytes32(block.timestamp % (1 << 32));

        _emitSnapshotEvent(token, encodedSnapshot);
    }

    /// @notice Called before a position is updated to capture price/liquidity snapshot
    /// @dev Inserts a new snapshot if liquidity is changing
    function beforeUpdatePosition(address, PoolKey memory poolKey, PositionKey memory, int128 liquidityDelta)
        external
        override
        onlyCore
    {
        if (liquidityDelta != 0) {
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token1);
        }
    }

    /// @notice Called before a swap to capture price/liquidity snapshot
    /// @dev Inserts a new snapshot if a swap is occurring
    function beforeSwap(address, PoolKey memory poolKey, int128 amount, bool, SqrtRatio, uint256)
        external
        override
        onlyCore
    {
        if (amount != 0) {
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token1);
        }
    }

    /// @inheritdoc IOracle
    function expandCapacity(address token, uint32 minCapacity) external returns (uint32 capacity) {
        Counts memory c = counts[token];

        if (c.capacity < minCapacity) {
            for (uint256 i = c.capacity; i < minCapacity; i++) {
                // Simply initialize the slot, it will be overwritten
                snapshots[token][i] = Snapshot(1, 0, 0);
            }
            c.capacity = minCapacity;
            counts[token] = c;
        }

        capacity = c.capacity;
    }

    /// @notice Searches for the latest snapshot with timestamp <= time within a logical range
    /// @dev Searches the logical range [min, maxExclusive) for the latest snapshot with timestamp <= time.
    ///      See logicalIndexToStorageIndex for an explanation of logical indices.
    ///      We make the assumption that all snapshots for the token were written within (2**32 - 1) seconds of the current block timestamp
    /// @param c The counts struct containing snapshot metadata
    /// @param token The token address to search snapshots for
    /// @param time The target timestamp to search for
    /// @param logicalMin The minimum logical index to search from
    /// @param logicalMaxExclusive The maximum logical index to search to (exclusive)
    /// @return logicalIndex The logical index of the found snapshot
    /// @return snapshot The snapshot data at the found index
    function searchRangeForPrevious(
        Counts memory c,
        address token,
        uint256 time,
        uint256 logicalMin,
        uint256 logicalMaxExclusive
    ) private view returns (uint256 logicalIndex, Snapshot memory snapshot) {
        unchecked {
            if (logicalMin >= logicalMaxExclusive) {
                revert NoPreviousSnapshotExists(token, time);
            }

            uint32 current = uint32(block.timestamp);
            uint32 targetDiff = current - uint32(time);

            mapping(uint256 => Snapshot) storage tSnapshots = snapshots[token];

            uint256 left = logicalMin;
            uint256 right = logicalMaxExclusive - 1;
            while (left < right) {
                uint256 mid = (left + right + 1) >> 1;
                Snapshot memory midSnapshot = tSnapshots[logicalIndexToStorageIndex(c.index, c.count, mid)];
                if (current - midSnapshot.timestamp >= targetDiff) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }
            snapshot = tSnapshots[logicalIndexToStorageIndex(c.index, c.count, left)];
            if (current - snapshot.timestamp < targetDiff) {
                revert NoPreviousSnapshotExists(token, time);
            }
            return (left, snapshot);
        }
    }
    /// @inheritdoc IOracle

    function findPreviousSnapshot(address token, uint256 time)
        public
        view
        returns (uint256 count, uint256 logicalIndex, Snapshot memory snapshot)
    {
        if (time > block.timestamp) revert FutureTime();

        Counts memory c = counts[token];
        count = c.count;
        (logicalIndex, snapshot) = searchRangeForPrevious(c, token, time, 0, count);
    }

    /// @notice Computes cumulative values at a given time by extrapolating from a previous snapshot
    /// @dev Uses linear interpolation between snapshots or current pool state for extrapolation
    /// @param c The counts struct containing snapshot metadata
    /// @param token The token address to extrapolate for
    /// @param atTime The timestamp to extrapolate to
    /// @param logicalIndex The logical index of the base snapshot
    /// @param snapshot The base snapshot to extrapolate from
    /// @return secondsPerLiquidityCumulative The extrapolated seconds per liquidity cumulative
    /// @return tickCumulative The extrapolated tick cumulative
    function extrapolateSnapshotInternal(
        Counts memory c,
        address token,
        uint256 atTime,
        uint256 logicalIndex,
        Snapshot memory snapshot
    ) private view returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) {
        unchecked {
            secondsPerLiquidityCumulative = snapshot.secondsPerLiquidityCumulative;
            tickCumulative = snapshot.tickCumulative;
            uint32 timePassed = uint32(atTime) - snapshot.timestamp;
            if (timePassed != 0) {
                if (logicalIndex == c.count - 1) {
                    // Use current pool state.
                    bytes32 poolId = getPoolKey(token).toPoolId();
                    (, int32 tick, uint128 liquidity) = CORE.poolState(poolId);

                    tickCumulative += int64(tick) * int64(uint64(timePassed));
                    secondsPerLiquidityCumulative +=
                        (uint160(timePassed) << 128) / uint160(FixedPointMathLib.max(1, liquidity));
                } else {
                    // Use the next snapshot.
                    Snapshot memory next =
                        snapshots[token][logicalIndexToStorageIndex(c.index, c.count, logicalIndex + 1)];

                    uint32 timestampDifference = next.timestamp - snapshot.timestamp;

                    tickCumulative += int64(
                        int256(uint256(timePassed)) * (next.tickCumulative - snapshot.tickCumulative)
                            / int256(uint256(timestampDifference))
                    );
                    secondsPerLiquidityCumulative += uint160(
                        (
                            uint256(timePassed)
                                * (next.secondsPerLiquidityCumulative - snapshot.secondsPerLiquidityCumulative)
                        ) / timestampDifference
                    );
                }
            }
        }
    }

    /// @inheritdoc IOracle
    function extrapolateSnapshot(address token, uint256 atTime)
        public
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
    {
        if (atTime > block.timestamp) revert FutureTime();

        Counts memory c = counts[token];
        (uint256 logicalIndex, Snapshot memory snapshot) = searchRangeForPrevious(c, token, atTime, 0, c.count);
        (secondsPerLiquidityCumulative, tickCumulative) =
            extrapolateSnapshotInternal(c, token, atTime, logicalIndex, snapshot);
    }

    /// @inheritdoc IOracle
    function getExtrapolatedSnapshotsForSortedTimestamps(address token, uint256[] memory timestamps)
        public
        view
        returns (Observation[] memory observations)
    {
        unchecked {
            if (timestamps.length == 0) revert ZeroTimestampsProvided();
            uint256 startTime = timestamps[0];
            uint256 endTime = timestamps[timestamps.length - 1];
            if (endTime < startTime) revert EndTimeLessThanStartTime();

            Counts memory c = counts[token];
            (uint256 indexFirst,) = searchRangeForPrevious(c, token, startTime, 0, c.count);
            (uint256 indexLast,) = searchRangeForPrevious(c, token, endTime, indexFirst, c.count);

            observations = new Observation[](timestamps.length);
            uint256 lastTimestamp;
            for (uint256 i = 0; i < timestamps.length; i++) {
                uint256 timestamp = timestamps[i];

                if (timestamp < lastTimestamp) {
                    revert TimestampsNotSorted();
                } else if (timestamp > block.timestamp) {
                    revert FutureTime();
                }

                (uint256 logicalIndex, Snapshot memory snapshot) =
                    searchRangeForPrevious(c, token, timestamp, indexFirst, indexLast + 1);
                (uint160 spcCumulative, int64 tcCumulative) =
                    extrapolateSnapshotInternal(c, token, timestamp, logicalIndex, snapshot);
                observations[i] = Observation(spcCumulative, tcCumulative);
                indexFirst = logicalIndex;
                lastTimestamp = timestamp;
            }
        }
    }
}
