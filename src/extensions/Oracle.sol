// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey, Bounds} from "../types/positionKey.sol";
import {NATIVE_TOKEN_ADDRESS} from "../interfaces/IFlashAccountant.sol";
import {ICore, UpdatePositionParameters, SwapParameters} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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

contract Oracle is ExposedStorage, BaseExtension {
    error PairsWithNativeTokenOnly();
    error FeeMustBeZero();
    error TickSpacingMustBeMaximum();
    error BoundsMustBeMaximum();
    error FutureTime();
    error NoPreviousSnapshotExists(address token, uint64 time);
    error EndTimeLessThanStartTime();
    error TimestampsNotSorted();
    error ZeroTimestampsProvided();

    event SnapshotInserted(
        address indexed token, uint64 timestamp, uint160 secondsPerLiquidityCumulative, int64 tickCumulative
    );

    using CoreLib for ICore;

    // all snapshots are taken with respect to this snapshot.
    // this allows the contract to function for 2^32-1 seconds from the time it is deployed before it must be redeployed
    // that is equivalent to 136.102208 years, so if it is deployed in 2025, it must be redeployed in the year 2161
    uint64 public immutable timestampOffset;

    struct Snapshot {
        uint32 secondsSinceOffset;
        // can be used to compute harmonic mean liquidity over a period of time, in order to determine the safety of the oracle
        uint160 secondsPerLiquidityCumulative;
        // can be used to compute a time weighted average tick over a period of time
        int64 tickCumulative;
    }

    struct Counts {
        // The index of the last snapshot that was written
        uint64 index;
        // The number of snapshots that have been written for the pool
        uint64 count;
        // The maximum number of snapshots that will be stored
        uint64 capacity;
    }

    mapping(address token => Counts) public counts;
    mapping(address token => mapping(uint256 index => Snapshot snapshot)) public snapshots;

    constructor(ICore core) BaseExtension(core) {
        // This assumption is used throughout the code, so we assert it in the constructor so that everything fails if it isn't held
        assert(NATIVE_TOKEN_ADDRESS == address(0));
        timestampOffset = uint64(block.timestamp);
    }

    // The only allowed pool key for the given token
    function getPoolKey(address token) public view returns (PoolKey memory) {
        return PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token,
            fee: 0,
            tickSpacing: MAX_TICK_SPACING,
            extension: address(this)
        });
    }

    function secondsSinceOffset() public view returns (uint32) {
        unchecked {
            return uint32(uint64(block.timestamp) - timestampOffset);
        }
    }

    function secondsSinceOffsetToTimestamp(uint32 sso) public view returns (uint64) {
        unchecked {
            return timestampOffset + sso;
        }
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return oracleCallPoints();
    }

    function maybeInsertSnapshot(bytes32 poolId, address token) private {
        unchecked {
            Counts memory c = counts[token];
            // we know count is always g.t. 0 in the places this is called
            Snapshot memory last = snapshots[token][c.index];

            uint32 sso = secondsSinceOffset();
            uint32 lastSso = last.secondsSinceOffset;

            uint32 timePassed = sso - lastSso;
            if (timePassed == 0) return;

            uint128 liquidity = core.poolLiquidity(poolId);
            (, int32 tick) = core.poolPrice(poolId);

            if (c.index == c.count - 1) {
                if (c.capacity > c.count) {
                    c.index = c.count;
                    c.count++;
                } else {
                    c.index = 0;
                }
            } else {
                c.index++;
            }

            Snapshot memory snapshot = Snapshot({
                secondsSinceOffset: sso,
                secondsPerLiquidityCumulative: last.secondsPerLiquidityCumulative
                    + ((uint160(timePassed) << 128) / uint160(FixedPointMathLib.max(1, liquidity))),
                tickCumulative: last.tickCumulative + int64(uint64(timePassed)) * tick
            });

            snapshots[token][c.index] = snapshot;
            counts[token] = c;

            emit SnapshotInserted(
                token,
                secondsSinceOffsetToTimestamp(snapshot.secondsSinceOffset),
                snapshot.secondsPerLiquidityCumulative,
                snapshot.tickCumulative
            );
        }
    }

    function beforeInitializePool(address, PoolKey calldata key, int32) external override onlyCore {
        if (key.token0 != NATIVE_TOKEN_ADDRESS) revert PairsWithNativeTokenOnly();
        if (key.fee != 0) revert FeeMustBeZero();
        if (key.tickSpacing != MAX_TICK_SPACING) revert TickSpacingMustBeMaximum();

        address token = key.token1;

        // in case expandCapacity is called before the pool is initialized:
        //  remember we have the capacity since the snapshot storage has been initialized
        counts[token] = Counts({index: 0, count: 1, capacity: uint64(FixedPointMathLib.max(1, counts[token].capacity))});
        uint32 sso = secondsSinceOffset();
        snapshots[token][0] = Snapshot(sso, 0, 0);

        emit SnapshotInserted(token, secondsSinceOffsetToTimestamp(sso), 0, 0);
    }

    function beforeUpdatePosition(address, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        override
        onlyCore
    {
        if (params.bounds.lower != MIN_TICK || params.bounds.upper != MAX_TICK) {
            revert BoundsMustBeMaximum();
        }

        if (params.liquidityDelta != 0) {
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token1);
        }
    }

    function beforeSwap(address, PoolKey memory poolKey, SwapParameters memory params) external override onlyCore {
        if (params.amount != 0) {
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token1);
        }
    }

    // Expands the capacity of the list of snapshots for the given token
    function expandCapacity(address token, uint64 minCapacity) external returns (uint64 capacity) {
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

    // Minimal set of efficient view methods that expose the data

    // returns the physical index of the oldest snapshot in the circular array
    function _firstIndex(address token) internal view returns (uint256) {
        Counts memory c = counts[token];
        return (c.index + c.capacity - (c.count - 1)) % c.capacity;
    }

    // given a logical index [0, count), returns the snapshot from storage
    function _getSnapshotLogical(address token, uint256 logicalIndex) internal view returns (Snapshot memory) {
        uint256 capacity = counts[token].capacity;
        uint256 first = _firstIndex(token);
        uint256 physicalIndex = (first + logicalIndex) % capacity;
        return snapshots[token][physicalIndex];
    }

    // Searches the logical range [min, maxExclusive) for the snapshot with secondsSinceOffset <= target.
    function searchRangeForPrevious(address token, uint64 time, uint256 logicalMin, uint256 logicalMaxExclusive)
        private
        view
        returns (uint256 logicalIndex, Snapshot memory snapshot)
    {
        unchecked {
            if (time < timestampOffset || logicalMin >= logicalMaxExclusive) {
                revert NoPreviousSnapshotExists(token, time);
            }
            // Our snapshot times are stored as uint32 relative to timestampOffset.
            assert(time < timestampOffset + type(uint32).max);
            uint32 targetSso = uint32(time - timestampOffset);

            uint256 left = logicalMin;
            uint256 right = logicalMaxExclusive - 1;
            while (left < right) {
                uint256 mid = (left + right + 1) >> 1;
                Snapshot memory midSnapshot = _getSnapshotLogical(token, mid);
                if (midSnapshot.secondsSinceOffset <= targetSso) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }
            snapshot = _getSnapshotLogical(token, left);
            if (snapshot.secondsSinceOffset > targetSso) {
                revert NoPreviousSnapshotExists(token, time);
            }
            return (left, snapshot);
        }
    }

    // Returns the snapshot with greatest timestamp ≤ the given time.
    function findPreviousSnapshot(address token, uint64 time)
        public
        view
        returns (uint256 count, uint256 logicalIndex, Snapshot memory snapshot)
    {
        Counts memory c = counts[token];
        count = c.count;
        (logicalIndex, snapshot) = searchRangeForPrevious(token, time, 0, count);
    }

    // Computes cumulative values at a given time by extrapolating from a previous snapshot.
    function extrapolateSnapshotInternal(
        address token,
        uint64 atTime,
        uint256 logicalIndex,
        uint256 count,
        Snapshot memory snapshot
    ) private view returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) {
        if (atTime > block.timestamp) revert FutureTime();
        unchecked {
            secondsPerLiquidityCumulative = snapshot.secondsPerLiquidityCumulative;
            tickCumulative = snapshot.tickCumulative;
            uint32 timePassed = uint32(atTime - timestampOffset - snapshot.secondsSinceOffset);
            if (timePassed != 0) {
                int32 tick;
                uint128 liquidity;
                if (logicalIndex == count - 1) {
                    // Use current pool state.
                    bytes32 poolId = getPoolKey(token).toPoolId();
                    (, tick) = core.poolPrice(poolId);
                    liquidity = core.poolLiquidity(poolId);
                } else {
                    // Use the next snapshot.
                    Snapshot memory next = _getSnapshotLogical(token, logicalIndex + 1);
                    tick = int32(
                        (next.tickCumulative - snapshot.tickCumulative)
                            / int64(uint64(next.secondsSinceOffset - snapshot.secondsSinceOffset))
                    );
                    liquidity = uint128(
                        (type(uint128).max)
                            / (
                                (next.secondsPerLiquidityCumulative - snapshot.secondsPerLiquidityCumulative)
                                    / (next.secondsSinceOffset - snapshot.secondsSinceOffset)
                            )
                    );
                }
                tickCumulative += int64(tick) * int64(uint64(timePassed));
                secondsPerLiquidityCumulative +=
                    (uint160(timePassed) << 128) / uint160(FixedPointMathLib.max(1, liquidity));
            }
        }
    }

    // Returns cumulative snapshot values at time `atTime`.
    function extrapolateSnapshot(address token, uint64 atTime)
        public
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
    {
        uint256 count = counts[token].count;
        (uint256 logicalIndex, Snapshot memory snapshot) = searchRangeForPrevious(token, atTime, 0, count);
        (secondsPerLiquidityCumulative, tickCumulative) =
            extrapolateSnapshotInternal(token, atTime, logicalIndex, count, snapshot);
    }

    struct Observation {
        uint160 secondsPerLiquidityCumulative;
        int64 tickCumulative;
    }

    // Returns extrapolated snapshots at each of the provided sorted timestamps.
    function getExtrapolatedSnapshotsForSortedTimestamps(address token, uint64[] memory timestamps)
        public
        view
        returns (Observation[] memory observations)
    {
        unchecked {
            if (timestamps.length == 0) revert ZeroTimestampsProvided();
            uint64 startTime = timestamps[0];
            uint64 endTime = timestamps[timestamps.length - 1];
            if (endTime < startTime) revert EndTimeLessThanStartTime();

            uint256 count = counts[token].count;
            (uint256 indexFirst,) = searchRangeForPrevious(token, startTime, 0, count);
            (uint256 indexLast,) = searchRangeForPrevious(token, endTime, indexFirst, count);

            observations = new Observation[](timestamps.length);
            uint64 lastTimestamp;
            for (uint256 i = 0; i < timestamps.length;) {
                uint64 timestamp = timestamps[i];
                if (timestamp < lastTimestamp) {
                    revert TimestampsNotSorted();
                }
                (uint256 logicalIndex, Snapshot memory snapshot) =
                    searchRangeForPrevious(token, timestamp, indexFirst, indexLast + 1);
                (uint160 spcCumulative, int64 tcCumulative) =
                    extrapolateSnapshotInternal(token, timestamp, logicalIndex, count, snapshot);
                observations[i] = Observation(spcCumulative, tcCumulative);
                indexFirst = logicalIndex;
                lastTimestamp = timestamp;
                ++i;
            }
        }
    }
}
