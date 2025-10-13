// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {IOracle} from "../interfaces/extensions/IOracle.sol";
import {OracleLib} from "../libraries/OracleLib.sol";
import {amount1Delta} from "../math/delta.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {MIN_SQRT_RATIO} from "../types/sqrtRatio.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Observation} from "../types/observation.sol";

/// @notice Thrown when the number of intervals is invalid (0 or max uint32)
error InvalidNumIntervals();

/// @notice Thrown when the period is invalid (0)
error InvalidPeriod();

/// @notice Gets the timestamps for snapshots that must be fetched for a given period
/// @dev Calculates timestamps for the range [endTime - (numIntervals * period), endTime]
/// @param endTime The end timestamp of the period
/// @param numIntervals The number of intervals to divide the period into
/// @param period The duration of each interval in seconds
/// @return timestamps Array of timestamps for the required snapshots
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

/// @title Price Fetcher
/// @author Ekubo Protocol
/// @notice Provides functions to fetch historical price data and calculate time-weighted averages
/// @dev Uses the Oracle extension to access historical price and liquidity data for analysis
contract PriceFetcher {
    using OracleLib for *;

    /// @notice Thrown when end time is not greater than start time
    error EndTimeMustBeGreaterThanStartTime();

    /// @notice Thrown when trying to calculate volatility with insufficient periods
    error MinimumOnePeriodRealizedVolatility();

    /// @notice Thrown when volatility calculation requires more intervals
    error VolatilityRequiresMoreIntervals();

    /// @notice The Oracle extension contract used for historical data
    IOracle public immutable ORACLE;

    /// @notice Constructs the PriceFetcher with an Oracle instance
    /// @param _oracle The Oracle extension to use for historical data
    constructor(IOracle _oracle) {
        ORACLE = _oracle;
    }

    /// @notice Represents time-weighted average data for a period
    /// @dev Contains both liquidity and price (tick) averages
    struct PeriodAverage {
        /// @notice Time-weighted average liquidity for the period
        uint128 liquidity;
        /// @notice Time-weighted average tick for the period
        int32 tick;
    }

    /// @notice Gets time-weighted averages over a specified period
    /// @dev The returned tick always represents quoteToken / baseToken
    /// @param baseToken The base token address
    /// @param quoteToken The quote token address
    /// @param startTime The start timestamp of the period
    /// @param endTime The end timestamp of the period
    /// @return The period averages for liquidity and tick
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
                    ORACLE.extrapolateSnapshot(otherToken, endTime);
                (uint160 secondsPerLiquidityCumulativeStart, int64 tickCumulativeStart) =
                    ORACLE.extrapolateSnapshot(otherToken, startTime);

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

    /// @notice Gets historical period averages for multiple intervals
    /// @dev Calculates time-weighted averages for each period in the specified range
    /// @param baseToken The base token address
    /// @param quoteToken The quote token address
    /// @param endTime The end timestamp of the range
    /// @param numIntervals The number of intervals to calculate
    /// @param period The duration of each interval in seconds
    /// @return averages Array of period averages for each interval
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

                Observation[] memory observations =
                    ORACLE.getExtrapolatedSnapshotsForSortedTimestamps(otherToken, timestamps);

                // for each but the last observation, populate the period
                for (uint256 i = 0; i < numIntervals; i++) {
                    Observation start = observations[i];
                    Observation end = observations[i + 1];

                    averages[i] = PeriodAverage(
                        uint128(
                            (uint160(period) << 128)
                                / (end.secondsPerLiquidityCumulative() - start.secondsPerLiquidityCumulative())
                        ),
                        tickSign * int32((end.tickCumulative() - start.tickCumulative()) / int64(uint64(period)))
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

    /// @notice Gets available historical period averages, adjusting for data availability
    /// @dev Returns as much historical data as available, potentially fewer intervals than requested
    /// @param baseToken The base token address
    /// @param quoteToken The quote token address
    /// @param endTime The end timestamp of the range
    /// @param numIntervals The requested number of intervals
    /// @param period The duration of each interval in seconds
    /// @return startTime The actual start time of the returned data
    /// @return averages Array of available period averages
    function getAvailableHistoricalPeriodAverages(
        address baseToken,
        address quoteToken,
        uint64 endTime,
        uint32 numIntervals,
        uint32 period
    ) public view returns (uint64 startTime, PeriodAverage[] memory averages) {
        uint256 earliestObservationTime = FixedPointMathLib.max(
            ORACLE.getEarliestSnapshotTimestamp(baseToken), ORACLE.getEarliestSnapshotTimestamp(quoteToken)
        );

        // no observations available for the period, return an empty array
        if (earliestObservationTime >= endTime) {
            return (endTime, new PeriodAverage[](0));
        }

        uint256 queryStartTime = uint256(endTime) - (uint256(numIntervals) * period);

        if (queryStartTime >= earliestObservationTime) {
            return
                (
                    uint64(queryStartTime),
                    getHistoricalPeriodAverages(baseToken, quoteToken, endTime, numIntervals, period)
                );
        } else {
            startTime = uint64(((earliestObservationTime + (period - 1)) / period) * period);

            numIntervals = uint32((endTime - startTime) / period);

            averages = getHistoricalPeriodAverages(baseToken, quoteToken, endTime, numIntervals, period);
        }
    }

    /// @notice Calculates realized volatility over a specified period
    /// @dev Computes volatility based on tick price movements between periods
    /// @param baseToken The base token address
    /// @param quoteToken The quote token address
    /// @param endTime The end timestamp of the period
    /// @param numIntervals The number of intervals to analyze (must be >= 2)
    /// @param period The duration of each interval in seconds
    /// @param extrapolatedTo The time period to extrapolate volatility to
    /// @return realizedVolatilityInTicks The calculated realized volatility in ticks
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

    /// @notice Gets oracle token averages for multiple tokens over a specified period
    /// @dev Returns time-weighted averages for tokens that have sufficient oracle data
    /// @param observationPeriod The period in seconds to calculate averages over
    /// @param baseTokens Array of token addresses to get averages for
    /// @return endTime The end timestamp used for calculations (current block timestamp)
    /// @return results Array of period averages for each token (empty if insufficient data)
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
                    uint256 maxPeriodForToken = ORACLE.getMaximumObservationPeriod(token);

                    if (maxPeriodForToken >= observationPeriod) {
                        results[i] = getAveragesOverPeriod(token, NATIVE_TOKEN_ADDRESS, startTime, endTime);
                    }
                }
            }
        }
    }
}
