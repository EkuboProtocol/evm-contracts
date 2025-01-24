// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Oracle} from "../extensions/Oracle.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {amount0Delta} from "../math/delta.sol";
import {tickToSqrtRatio, MAX_SQRT_RATIO} from "../math/ticks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Gets the timestamps for the shorthand of end time, num intervals and period
function getTimestampsForPeriod(uint64 endTime, uint32 numIntervals, uint32 period)
    pure
    returns (uint64[] memory timestamps)
{
    timestamps = new uint64[](numIntervals);

    uint64 t = endTime;
    while (numIntervals > 0) {
        timestamps[numIntervals - 1] = t;
        t -= period;
        numIntervals--;
    }
}

contract PriceFetcher {
    error EndTimeMustBeGreaterThanStartTime();
    error MinimumOnePeriodRealizedVolatility();

    Oracle public immutable oracle;
    // we store a copy here for efficiency
    address private immutable _oracleToken;

    constructor(Oracle _oracle) {
        oracle = _oracle;
        _oracleToken = oracle.oracleToken();
    }

    function getEarliestSnapshotTimestamp(address token) private view returns (uint256) {
        uint256 count = oracle.snapshotCount(token);
        if (count == 0) {
            // if there are no snapshots, return a timestamp that will never be considered valid
            return type(uint256).max;
        }
        (uint32 secondsSinceOffset,,) = oracle.snapshots(token, 0);
        return oracle.timestampOffset() + secondsSinceOffset;
    }

    function getMaximumObservationPeriod(address token) private view returns (uint32) {
        uint256 earliest = getEarliestSnapshotTimestamp(token);
        if (earliest > block.timestamp) return 0;
        return uint32(block.timestamp - earliest);
    }

    struct Result {
        uint256 priceX128;
        uint128 liquidity;
    }

    // The returned tick always represents quoteToken / baseToken
    function getAveragesOverPeriod(address baseToken, address quoteToken, uint64 startTime, uint64 endTime)
        public
        returns (uint128 liquidity, int32 tick)
    {
        if (endTime <= startTime) revert EndTimeMustBeGreaterThanStartTime();

        if (baseToken == _oracleToken) {
            (uint160 secondsPerLiquidityCumulativeEnd, int64 tickCumulativeEnd) =
                oracle.extrapolateSnapshot(quoteToken, endTime);
            (uint160 secondsPerLiquidityCumulativeStart, int64 tickCumulativeStart) =
                oracle.extrapolateSnapshot(quoteToken, startTime);

            liquidity = uint128(
                (uint160(endTime - startTime) << 128)
                    / (secondsPerLiquidityCumulativeEnd - secondsPerLiquidityCumulativeStart)
            );
            tick = int32((tickCumulativeEnd - tickCumulativeStart) / int64(endTime - startTime));
        } else if (quoteToken == _oracleToken) {
            // we just flip the tick
            (uint128 liquidityBase, int32 tickBase) = getAveragesOverPeriod(_oracleToken, baseToken, startTime, endTime);
            return (liquidityBase, -tickBase);
        } else {
            (uint128 liquidityBase, int32 tickBase) = getAveragesOverPeriod(_oracleToken, baseToken, startTime, endTime);
            (uint128 liquidityQuote, int32 tickQuote) =
                getAveragesOverPeriod(_oracleToken, quoteToken, startTime, endTime);

            uint128 amountBase = amount0Delta(tickToSqrtRatio(tickBase), MAX_SQRT_RATIO, liquidityBase, false);
            uint128 amountQuote = amount0Delta(tickToSqrtRatio(tickQuote), MAX_SQRT_RATIO, liquidityQuote, false);

            tick = tickQuote - tickBase;
            liquidity = uint128(FixedPointMathLib.sqrt(uint256(amountBase) * uint256(amountQuote)));
        }
    }

    function getPricesInOracleToken(uint64 observationPeriod, address[] memory baseTokens)
        public
        returns (address oracleToken, Result[] memory results)
    {
        oracleToken = _oracleToken;
        results = new Result[](baseTokens.length);
        unchecked {
            for (uint256 i = 0; i < baseTokens.length; i++) {
                address token = baseTokens[i];
                if (oracleToken == token) {
                    results[i] = Result(1 << 128, type(uint128).max);
                } else {
                    uint256 maxPeriod = getMaximumObservationPeriod(token);

                    if (maxPeriod >= observationPeriod) {
                        (uint128 liquidity, int32 tick) = getAveragesOverPeriod(
                            token, oracleToken, uint64(block.timestamp - observationPeriod), uint64(block.timestamp)
                        );
                        uint256 sqrtRatio = tickToSqrtRatio(tick);
                        uint256 priceX128 = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);
                        results[i] = Result(priceX128, liquidity);
                    }
                }
            }
        }
    }

    function getBlockPrices(uint64 observationPeriod, address[] memory baseTokens)
        public
        returns (uint256 blockTimestamp, uint256 baseFee, address oracleToken, Result[] memory results)
    {
        blockTimestamp = block.timestamp;
        baseFee = block.basefee;
        (oracleToken, results) = getPricesInOracleToken(observationPeriod, baseTokens);
    }
}
