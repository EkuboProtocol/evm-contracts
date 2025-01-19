// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";
import {ICore, UpdatePositionParameters, SwapParameters} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../math/ticks.sol";

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
            return timestampOffset + uint64(sso);
        }
    }

    error NoPreviousSnapshotExists(address token, uint64 time);
    error MustRedeployContract();

    // Returns the snapshot with the greatest secondsSinceOffsetToTimestamp(snapshot.secondsSinceOffset) that is less than or equal to the given time
    function findPreviousSnapshot(address token, uint64 time) public view returns (uint256, Snapshot memory) {
        unchecked {
            if (time < timestampOffset) revert NoPreviousSnapshotExists(token, time);
            if (time > timestampOffset + type(uint32).max) revert MustRedeployContract();

            uint32 targetSso = uint32(time - timestampOffset);

            uint256 count = snapshotCount[token];
            if (count == 0) revert NoPreviousSnapshotExists(token, time);

            uint256 left = 0;
            uint256 right = count - 1;

            while (left < right) {
                uint256 mid = (left + right + 1) >> 1;
                uint64 midSso = snapshots[token][mid].secondsSinceOffset;
                if (midSso <= targetSso) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }

            Snapshot memory snap = snapshots[token][left];
            if (snap.secondsSinceOffset > targetSso) {
                revert NoPreviousSnapshotExists(token, time);
            }
            return (left, snap);
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
        uint256 count = snapshotCount[token];
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
            secondsPerLiquidityCumulative: liquidity > 0
                ? last.secondsPerLiquidityCumulative + (uint160(timePassed) << 128) / liquidity
                : last.secondsPerLiquidityCumulative,
            tickCumulative: last.tickCumulative + int64(uint64(timePassed)) * tick
        });

        snapshots[token][count] = snapshot;
        unchecked {
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

        maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token0 == oracleToken ? poolKey.token1 : poolKey.token0);
    }

    function beforeSwap(address, PoolKey memory poolKey, SwapParameters memory) external override onlyCore {
        maybeInsertSnapshot(poolKey.toPoolId(), poolKey.token0 == oracleToken ? poolKey.token1 : poolKey.token0);
    }
}
