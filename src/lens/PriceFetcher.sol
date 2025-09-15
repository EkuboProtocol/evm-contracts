// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Oracle} from "../extensions/Oracle.sol";
import {OracleLib} from "../libraries/OracleLib.sol";
import {amount1Delta} from "../math/delta.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {MIN_SQRT_RATIO} from "../types/sqrtRatio.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error InvalidNumIntervals();
error InvalidPeriod();

// Gets the timestamps for the snapshots that must be fetched for the given period [endTime - (numIntervals * period), endTime]
function getTimestampsForPeriod(uint256 endTime, uint32 numIntervals, uint32 period)
    pure
    returns (uint256[] memory timestamps)
{
    if (numIntervals == 0 || numIntervals == type(uint32).max) revert InvalidNumIntervals();
    if (period == 0) revert InvalidPeriod();

    timestamps = new uint256[](numIntervals + 1);
    for (uint256 i = 0; i <= numIntervals;) {
        timestamps[i] = endTime - (numIntervals - i) * period;
        unchecked {
            i++;
        }
    }
}

contract PriceFetcher {
    using OracleLib for *;

    error EndTimeMustBeGreaterThanStartTime();
    error MinimumOnePeriodRealizedVolatility();
    error VolatilityRequiresMoreIntervals();

    Oracle public immutable oracle;

    constructor(Oracle _oracle) {
        oracle = _oracle;
    }

    struct PeriodAverage {
        uint128 liquidity;
        int32 tick;
    }

    // The returned tick always represents quoteToken / baseToken
    function getAveragesOverPeriod(address baseToken, address quoteToken, uint64 startTime, uint64 endTime)
        public
        view
        returns (PeriodAverage memory)
    {
        if (endTime <= startTime) revert EndTimeMustBeGreaterThanStartTime();

        unchecked {
            bool baseIsOracleToken = baseToken == NATIVE_TOKEN_ADDRESS;
            if (baseIsOracleToken || quoteToken == NATIVE_TOKEN_ADDRESS) {
                (int32 tickSign, address otherToken) =
                    baseIsOracleToken ? (int32(1), quoteToken) : (int32(-1), baseToken);

                (uint160 secondsPerLiquidityCumulativeEnd, int64 tickCumulativeEnd) =
                    oracle.extrapolateSnapshot(otherToken, endTime);
                (uint160 secondsPerLiquidityCumulativeStart, int64 tickCumulativeStart) =
                    oracle.extrapolateSnapshot(otherToken, startTime);

                return PeriodAverage(
                    uint128(
                        (uint160(endTime - startTime) << 128)
                            / (secondsPerLiquidityCumulativeEnd - secondsPerLiquidityCumulativeStart)
                    ),
                    tickSign * int32((tickCumulativeEnd - tickCumulativeStart) / int64(endTime - startTime))
                );
            } else {
                PeriodAverage memory base = getAveragesOverPeriod(NATIVE_TOKEN_ADDRESS, baseToken, startTime, endTime);
                PeriodAverage memory quote = getAveragesOverPeriod(NATIVE_TOKEN_ADDRESS, quoteToken, startTime, endTime);

                uint128 amountBase = amount1Delta(tickToSqrtRatio(base.tick), MIN_SQRT_RATIO, base.liquidity, false);
                uint128 amountQuote = amount1Delta(tickToSqrtRatio(quote.tick), MIN_SQRT_RATIO, quote.liquidity, false);

                return PeriodAverage(
                    uint128(FixedPointMathLib.sqrt(uint256(amountBase) * uint256(amountQuote))), quote.tick - base.tick
                );
            }
        }
    }

    function getHistoricalPeriodAverages(
        address baseToken,
        address quoteToken,
        uint64 endTime,
        uint32 numIntervals,
        uint32 period
    ) public view returns (PeriodAverage[] memory averages) {
        unchecked {
            bool baseIsOracleToken = baseToken == NATIVE_TOKEN_ADDRESS;
            if (baseIsOracleToken || quoteToken == NATIVE_TOKEN_ADDRESS) {
                (int32 tickSign, address otherToken) =
                    baseIsOracleToken ? (int32(1), quoteToken) : (int32(-1), baseToken);

                uint256[] memory timestamps = getTimestampsForPeriod(endTime, numIntervals, period);
                averages = new PeriodAverage[](numIntervals);

                Oracle.Observation[] memory observations =
                    oracle.getExtrapolatedSnapshotsForSortedTimestamps(otherToken, timestamps);

                // for each but the last observation, populate the period
                for (uint256 i = 0; i < numIntervals; i++) {
                    Oracle.Observation memory start = observations[i];
                    Oracle.Observation memory end = observations[i + 1];

                    averages[i] = PeriodAverage(
                        uint128(
                            (uint160(period) << 128)
                                / (end.secondsPerLiquidityCumulative - start.secondsPerLiquidityCumulative)
                        ),
                        tickSign * int32((end.tickCumulative - start.tickCumulative) / int64(uint64(period)))
                    );
                }
            } else {
                PeriodAverage[] memory bases =
                    getHistoricalPeriodAverages(NATIVE_TOKEN_ADDRESS, baseToken, endTime, numIntervals, period);
                PeriodAverage[] memory quotes =
                    getHistoricalPeriodAverages(NATIVE_TOKEN_ADDRESS, quoteToken, endTime, numIntervals, period);

                averages = new PeriodAverage[](numIntervals);

                for (uint256 i = 0; i < bases.length; i++) {
                    PeriodAverage memory base = bases[i];
                    PeriodAverage memory quote = quotes[i];

                    uint128 amountBase = amount1Delta(tickToSqrtRatio(base.tick), MIN_SQRT_RATIO, base.liquidity, false);
                    uint128 amountQuote =
                        amount1Delta(tickToSqrtRatio(quote.tick), MIN_SQRT_RATIO, quote.liquidity, false);

                    averages[i] = PeriodAverage(
                        uint128(FixedPointMathLib.sqrt(uint256(amountBase) * uint256(amountQuote))),
                        quote.tick - base.tick
                    );
                }
            }
        }
    }

    function getAvailableHistoricalPeriodAverages(
        address baseToken,
        address quoteToken,
        uint64 endTime,
        uint32 numIntervals,
        uint32 period
    ) public view returns (uint64 startTime, PeriodAverage[] memory averages) {
        uint256 earliestObservationTime = FixedPointMathLib.max(
            oracle.getEarliestSnapshotTimestamp(baseToken), oracle.getEarliestSnapshotTimestamp(quoteToken)
        );

        // no observations available for the period, return an empty array
        if (earliestObservationTime >= endTime) {
            return (endTime, new PeriodAverage[](0));
        }

        uint256 queryStartTime = uint256(endTime) - (uint256(numIntervals) * period);

        if (queryStartTime >= earliestObservationTime) {
            return (
                uint64(queryStartTime),
                getHistoricalPeriodAverages(baseToken, quoteToken, endTime, numIntervals, period)
            );
        } else {
            startTime = uint64(((earliestObservationTime + (period - 1)) / period) * period);

            numIntervals = uint32((endTime - startTime) / period);

            averages = getHistoricalPeriodAverages(baseToken, quoteToken, endTime, numIntervals, period);
        }
    }

    function getRealizedVolatilityOverPeriod(
        address baseToken,
        address quoteToken,
        uint64 endTime,
        uint32 numIntervals,
        uint32 period,
        uint32 extrapolatedTo
    ) public view returns (uint256 realizedVolatilityInTicks) {
        if (numIntervals < 2) revert VolatilityRequiresMoreIntervals();
        PeriodAverage[] memory averages =
            getHistoricalPeriodAverages(baseToken, quoteToken, endTime, numIntervals, period);

        uint256 sum;
        for (uint256 i = 1; i < averages.length;) {
            unchecked {
                uint256 difference = FixedPointMathLib.abs(int256(averages[i].tick) - int256(averages[i - 1].tick));
                sum += difference * difference;
                i++;
            }
        }

        uint256 extrapolated = (sum * extrapolatedTo) / ((numIntervals - 1) * period);

        return FixedPointMathLib.sqrt(extrapolated);
    }

    function getOracleTokenAverages(uint64 observationPeriod, address[] memory baseTokens)
        public
        view
        returns (uint64 endTime, PeriodAverage[] memory results)
    {
        endTime = uint64(block.timestamp);
        uint64 startTime = endTime - observationPeriod;
        results = new PeriodAverage[](baseTokens.length);
        unchecked {
            for (uint256 i = 0; i < baseTokens.length; i++) {
                address token = baseTokens[i];
                if (token == NATIVE_TOKEN_ADDRESS) {
                    results[i] = PeriodAverage(type(uint128).max, 0);
                } else {
                    uint256 maxPeriodForToken = oracle.getMaximumObservationPeriod(token);

                    if (maxPeriodForToken >= observationPeriod) {
                        results[i] = getAveragesOverPeriod(token, NATIVE_TOKEN_ADDRESS, startTime, endTime);
                    }
                }
            }
        }
    }
}
