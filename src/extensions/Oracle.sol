// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";
import {ICore, UpdatePositionParameters, SwapParameters} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {amount0Delta} from "../math/delta.sol";
import {tickToSqrtRatio, MIN_TICK, MAX_TICK, MAX_TICK_SPACING, MAX_SQRT_RATIO} from "../math/ticks.sol";
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
    error MustRedeployContract();
    error EndTimeMustBeGreaterThanStartTime();

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

    function search(address token, uint64 time, uint256 minIndex, uint256 maxIndex)
        public
        view
        returns (uint256 index, Snapshot memory snapshot)
    {
        unchecked {
            if (time < timestampOffset) revert NoPreviousSnapshotExists(token, time);
            if (time > timestampOffset + type(uint32).max) revert MustRedeployContract();

            mapping(uint256 => Snapshot) storage tokenSnapshots = snapshots[token];

            uint32 targetSso = uint32(time - timestampOffset);

            uint256 left = minIndex;
            uint256 right = maxIndex;

            while (left < right) {
                uint256 mid = (left + right + 1) >> 1;
                uint64 midSso = tokenSnapshots[mid].secondsSinceOffset;
                if (midSso <= targetSso) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }

            Snapshot memory snap = tokenSnapshots[left];
            if (snap.secondsSinceOffset > targetSso) {
                revert NoPreviousSnapshotExists(token, time);
            }
            return (left, snap);
        }
    }

    // Returns the snapshot with the greatest secondsSinceOffsetToTimestamp(snapshot.secondsSinceOffset) that is less than or equal to the given time
    function findPreviousSnapshot(address token, uint64 time)
        public
        view
        returns (uint256 count, uint256 index, Snapshot memory snapshot)
    {
        count = snapshotCount[token];
        if (count == 0) revert NoPreviousSnapshotExists(token, time);

        (index, snapshot) = search(token, time, 0, count - 1);
    }

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

    function extrapolateSnapshot(address token, uint64 atTime)
        public
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
    {
        if (atTime > block.timestamp) revert FutureTime();

        (uint256 count, uint256 index, Snapshot memory snapshot) = findPreviousSnapshot(token, atTime);

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

    // The returned tick always represents quoteToken / baseToken
    function getAveragesOverPeriod(address baseToken, address quoteToken, uint64 startTime, uint64 endTime)
        public
        returns (uint128 liquidity, int32 tick)
    {
        if (endTime <= startTime) revert EndTimeMustBeGreaterThanStartTime();

        if (baseToken == oracleToken) {
            (uint160 secondsPerLiquidityCumulativeEnd, int64 tickCumulativeEnd) =
                extrapolateSnapshot(quoteToken, endTime);
            (uint160 secondsPerLiquidityCumulativeStart, int64 tickCumulativeStart) =
                extrapolateSnapshot(quoteToken, startTime);

            liquidity = uint128(
                (uint160(endTime - startTime) << 128)
                    / (secondsPerLiquidityCumulativeEnd - secondsPerLiquidityCumulativeStart)
            );
            tick = int32((tickCumulativeEnd - tickCumulativeStart) / int64(endTime - startTime));
        } else if (quoteToken == oracleToken) {
            // we just flip the tick
            (uint128 liquidityBase, int32 tickBase) = getAveragesOverPeriod(oracleToken, baseToken, startTime, endTime);
            return (liquidityBase, -tickBase);
        } else {
            (uint128 liquidityBase, int32 tickBase) = getAveragesOverPeriod(oracleToken, baseToken, startTime, endTime);
            (uint128 liquidityQuote, int32 tickQuote) =
                getAveragesOverPeriod(oracleToken, quoteToken, startTime, endTime);

            uint128 amountBase = amount0Delta(tickToSqrtRatio(tickBase), MAX_SQRT_RATIO, liquidityBase, false);
            uint128 amountQuote = amount0Delta(tickToSqrtRatio(tickQuote), MAX_SQRT_RATIO, liquidityQuote, false);

            tick = tickQuote - tickBase;
            liquidity = uint128(FixedPointMathLib.sqrt(uint256(amountBase) * uint256(amountQuote)));
        }
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return oracleCallPoints();
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
}
