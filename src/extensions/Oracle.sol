// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey, Bounds} from "../types/positionKey.sol";
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
    error PairsWithOracleTokenOnly();
    error FeeMustBeZero();
    error TickSpacingMustBeMaximum();
    error BoundsMustBeMaximum();
    error FutureTime();
    error NoPreviousSnapshotExists(address token, uint64 time);
    error EndTimeLessThanStartTime();
    error TimestampsNotSorted();
    error ZeroTimestampsProvided();

    event SnapshotEvent(
        address token, uint256 index, uint64 timestamp, uint160 secondsPerLiquidityCumulative, int64 tickCumulative
    );

    using CoreLib for ICore;

    address public immutable oracleToken;
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

    mapping(address token => uint256 count) public snapshotCount;
    mapping(address token => mapping(uint256 index => Snapshot snapshot)) public snapshots;

    constructor(ICore core, address _oracleToken) BaseExtension(core) {
        timestampOffset = uint64(block.timestamp);
        oracleToken = _oracleToken;
    }

    // The only allowed pool key for the given token
    function getPoolKey(address token) public view returns (PoolKey memory) {
        if (token < oracleToken) {
            return PoolKey({
                token0: token,
                token1: oracleToken,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                extension: address(this)
            });
        } else {
            return PoolKey({
                token0: oracleToken,
                token1: token,
                fee: 0,
                tickSpacing: MAX_TICK_SPACING,
                extension: address(this)
            });
        }
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
            uint256 count = snapshotCount[token];
            // we know count is always g.t. 0 in the places this is called
            Snapshot memory last = snapshots[token][count - 1];

            uint32 sso = secondsSinceOffset();
            uint32 lastSso = last.secondsSinceOffset;

            uint32 timePassed = sso - lastSso;
            if (timePassed == 0) return;

            uint128 liquidity = core.poolLiquidity(poolId);
            (, int32 tick) = core.poolPrice(poolId);

            // we always make the price as if it's oracleToken/token
            if (token > oracleToken) {
                tick = -tick;
            }

            snapshotCount[token] = count + 1;
            Snapshot memory snapshot = Snapshot({
                secondsSinceOffset: sso,
                secondsPerLiquidityCumulative: last.secondsPerLiquidityCumulative
                    + ((uint160(timePassed) << 128) / uint160(FixedPointMathLib.max(1, liquidity))),
                tickCumulative: last.tickCumulative + int64(uint64(timePassed)) * tick
            });

            snapshots[token][count] = snapshot;
            emit SnapshotEvent(
                token,
                count,
                secondsSinceOffsetToTimestamp(snapshot.secondsSinceOffset),
                snapshot.secondsPerLiquidityCumulative,
                snapshot.tickCumulative
            );
        }
    }

    function beforeInitializePool(address, PoolKey calldata key, int32) external override onlyCore {
        if (key.token0 != oracleToken && key.token1 != oracleToken) revert PairsWithOracleTokenOnly();
        if (key.fee != 0) revert FeeMustBeZero();
        if (key.tickSpacing != MAX_TICK_SPACING) revert TickSpacingMustBeMaximum();

        address token = key.token0 == oracleToken ? key.token1 : key.token0;

        snapshotCount[token] = 1;
        uint32 sso = secondsSinceOffset();
        snapshots[token][0] = Snapshot(sso, 0, 0);

        emit SnapshotEvent(token, 0, secondsSinceOffsetToTimestamp(sso), 0, 0);
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
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token0 == oracleToken ? poolKey.token1 : poolKey.token0);
        }
    }

    function beforeSwap(address, PoolKey memory poolKey, SwapParameters memory params) external override onlyCore {
        if (params.amount != 0) {
            maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token0 == oracleToken ? poolKey.token1 : poolKey.token0);
        }
    }

    // Efficient view methods that expose the data

    // Searches the given range of snapshots for the snapshot that has a timestamp <= the given time
    function searchRangeForPrevious(address token, uint64 time, uint256 minIndex, uint256 maxIndexExclusive)
        private
        view
        returns (uint256 index, Snapshot memory snapshot)
    {
        unchecked {
            if (time < timestampOffset || minIndex >= maxIndexExclusive) revert NoPreviousSnapshotExists(token, time);
            // you cannot query this contract for times that are beyond the maximum lifetime of this contract
            // but since 136 years is such a long time, we simply use an assert
            assert(time < timestampOffset + type(uint32).max);

            mapping(uint256 => Snapshot) storage tokenSnapshots = snapshots[token];

            uint32 targetSso = uint32(time - timestampOffset);

            uint256 left = minIndex;
            // safe subtraction because minIndex < maxIndexExclusive which implies maxIndexExclusive != 0
            uint256 right = maxIndexExclusive - 1;

            while (left < right) {
                uint256 mid = (left + right + 1) >> 1;
                snapshot = tokenSnapshots[mid];
                if (snapshot.secondsSinceOffset <= targetSso) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }

            // snap may not contain the last one, if we last checked the one to its right
            snapshot = tokenSnapshots[left];
            if (snapshot.secondsSinceOffset > targetSso) {
                revert NoPreviousSnapshotExists(token, time);
            }
            return (left, snapshot);
        }
    }

    // Returns the snapshot with the greatest secondsSinceOffset such that secondsSinceOffsetToTimestamp(secondsSinceOffset) is less than or equal to the given time
    function findPreviousSnapshot(address token, uint64 time)
        public
        view
        returns (uint256 count, uint256 index, Snapshot memory snapshot)
    {
        count = snapshotCount[token];
        (index, snapshot) = searchRangeForPrevious(token, time, 0, count);
    }

    function extrapolateSnapshotInternal(
        address token,
        uint64 atTime,
        uint256 index,
        uint256 count,
        Snapshot memory snapshot
    ) private view returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) {
        if (atTime > block.timestamp) revert FutureTime();

        unchecked {
            (secondsPerLiquidityCumulative, tickCumulative) =
                (snapshot.secondsPerLiquidityCumulative, snapshot.tickCumulative);

            // we know this subtraction will not underflow due to checks in findPreviousSnapshot
            uint32 timePassed = uint32(atTime - timestampOffset - snapshot.secondsSinceOffset);

            if (timePassed != 0) {
                int32 tick;
                uint128 liquidity;
                if (index == count - 1) {
                    // last snapshot, read current price and liquidity
                    bytes32 poolId = getPoolKey(token).toPoolId();
                    (, tick) = core.poolPrice(poolId);
                    if (token > oracleToken) {
                        tick = -tick;
                    }
                    liquidity = core.poolLiquidity(poolId);
                } else {
                    // otherwise take the difference between 2 snapshots to get the last value of the tick/liquidity
                    // at the time of the previous snapshot
                    Snapshot memory next = snapshots[token][index + 1];
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

    function extrapolateSnapshot(address token, uint64 atTime)
        public
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
    {
        uint256 count = snapshotCount[token];
        (uint256 index, Snapshot memory snapshot) = searchRangeForPrevious(token, atTime, 0, count);
        (secondsPerLiquidityCumulative, tickCumulative) =
            extrapolateSnapshotInternal(token, atTime, index, count, snapshot);
    }

    struct Observation {
        uint160 secondsPerLiquidityCumulative;
        int64 tickCumulative;
    }

    // Returns the snapshots of the cumulative values at each of the given timestamps
    // If you are only querying only 2 snapshots, prefer calling extrapolateSnapshot 2 times
    // This method is optimized for computing data over many snapshots in a time period << the total time the token was under observation
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

            uint256 count = snapshotCount[token];
            (uint256 indexFirst,) = searchRangeForPrevious(token, startTime, 0, count);
            (uint256 indexLast,) = searchRangeForPrevious(token, endTime, indexFirst, count);

            observations = new Observation[](timestamps.length);

            uint64 lastTimestamp;
            for (uint256 i = 0; i < timestamps.length;) {
                uint64 timestamp = timestamps[i];
                if (timestamp < lastTimestamp) {
                    revert TimestampsNotSorted();
                }

                // we do a search within just the range of [first, last+1)
                (uint256 index, Snapshot memory snapshot) =
                    searchRangeForPrevious(token, timestamp, indexFirst, indexLast + 1);

                (uint160 secondsPerLiquidityCumulative, int64 tickCumulative) =
                    extrapolateSnapshotInternal(token, timestamp, index, count, snapshot);

                observations[i] = Observation(secondsPerLiquidityCumulative, tickCumulative);

                // bump the indexFirst so we search a smaller range on the next iteration
                indexFirst = index;
                lastTimestamp = timestamp;
                i++;
            }
        }
    }
}
