// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Oracle} from "../extensions/Oracle.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {amount0Delta} from "../math/delta.sol";
import {tickToSqrtRatio, MAX_SQRT_RATIO} from "../math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS} from "../interfaces/ICore.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

error InvalidNumIntervals();
error InvalidPeriod();

// Gets the timestamps for the snapshots that must be fetched for the given period [endTime - (numIntervals * period), endTime]
function getTimestampsForPeriod(uint64 endTime, uint32 numIntervals, uint32 period)
    pure
    returns (uint64[] memory timestamps)
{
    if (numIntervals == 0 || numIntervals == type(uint32).max) revert InvalidNumIntervals();
    if (period == 0) revert InvalidPeriod();

    timestamps = new uint64[](numIntervals + 1);
    for (uint256 i = 0; i <= numIntervals;) {
        timestamps[i] = uint64(endTime - ((numIntervals - i) * period));
        unchecked {
            i++;
        }
    }
}

contract PriceFetcher {
    error EndTimeMustBeGreaterThanStartTime();
    error MinimumOnePeriodRealizedVolatility();
    error VolatilityRequiresMoreIntervals();

    Oracle public immutable oracle;
    // we store a copy here for efficiency
    address private immutable _oracleToken;
    uint64 private immutable _timestampOffset;

    constructor(Oracle _oracle) {
        oracle = _oracle;
        _oracleToken = oracle.oracleToken();
        _timestampOffset = oracle.timestampOffset();
    }

    function getEarliestSnapshotTimestamp(address token) private view returns (uint256) {
        if (token == _oracleToken) return _timestampOffset;

        uint256 count = oracle.snapshotCount(token);
        if (count == 0) {
            // if there are no snapshots, return a timestamp that will never be considered valid
            return type(uint256).max;
        }
        (uint32 secondsSinceOffset,,) = oracle.snapshots(token, 0);
        return _timestampOffset + secondsSinceOffset;
    }

    function getMaximumObservationPeriod(address token) private view returns (uint32) {
        uint256 earliest = getEarliestSnapshotTimestamp(token);
        if (earliest > block.timestamp) return 0;
        return uint32(block.timestamp - earliest);
    }

    struct PeriodAverage {
        uint128 liquidity;
        int32 tick;
    }

    // The returned tick always represents quoteToken / baseToken
    function getAveragesOverPeriod(address baseToken, address quoteToken, uint64 startTime, uint64 endTime)
        public
        returns (PeriodAverage memory)
    {
        if (endTime <= startTime) revert EndTimeMustBeGreaterThanStartTime();

        unchecked {
            bool baseIsOracleToken = baseToken == _oracleToken;
            if (baseIsOracleToken || quoteToken == _oracleToken) {
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
                PeriodAverage memory base = getAveragesOverPeriod(_oracleToken, baseToken, startTime, endTime);
                PeriodAverage memory quote = getAveragesOverPeriod(_oracleToken, quoteToken, startTime, endTime);

                uint128 amountBase = amount0Delta(tickToSqrtRatio(base.tick), MAX_SQRT_RATIO, base.liquidity, false);
                uint128 amountQuote = amount0Delta(tickToSqrtRatio(quote.tick), MAX_SQRT_RATIO, quote.liquidity, false);

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
            bool baseIsOracleToken = baseToken == _oracleToken;
            if (baseIsOracleToken || quoteToken == _oracleToken) {
                (int32 tickSign, address otherToken) =
                    baseIsOracleToken ? (int32(1), quoteToken) : (int32(-1), baseToken);

                uint64[] memory timestamps = getTimestampsForPeriod(endTime, numIntervals, period);
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
                    getHistoricalPeriodAverages(_oracleToken, baseToken, endTime, numIntervals, period);
                PeriodAverage[] memory quotes =
                    getHistoricalPeriodAverages(_oracleToken, quoteToken, endTime, numIntervals, period);

                averages = new PeriodAverage[](numIntervals);

                for (uint256 i = 0; i < bases.length; i++) {
                    PeriodAverage memory base = bases[i];
                    PeriodAverage memory quote = quotes[i];

                    uint128 amountBase = amount0Delta(tickToSqrtRatio(base.tick), MAX_SQRT_RATIO, base.liquidity, false);
                    uint128 amountQuote =
                        amount0Delta(tickToSqrtRatio(quote.tick), MAX_SQRT_RATIO, quote.liquidity, false);

                    averages[i] = PeriodAverage(
                        uint128(FixedPointMathLib.sqrt(uint256(amountBase) * uint256(amountQuote))),
                        quote.tick - base.tick
                    );
                }
            }
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
        returns (address oracleToken, PeriodAverage[] memory results)
    {
        oracleToken = _oracleToken;
        results = new PeriodAverage[](baseTokens.length);
        unchecked {
            for (uint256 i = 0; i < baseTokens.length; i++) {
                address token = baseTokens[i];
                if (token == _oracleToken) {
                    results[i] = PeriodAverage(type(uint128).max, 0);
                } else {
                    uint256 maxPeriodForToken = getMaximumObservationPeriod(token);

                    if (maxPeriodForToken >= observationPeriod) {
                        results[i] = getAveragesOverPeriod(
                            token, oracleToken, uint64(block.timestamp - observationPeriod), uint64(block.timestamp)
                        );
                    }
                }
            }
        }
    }

    // Useful information for routing bundled into a single call
    function getBlockInfoAndNativeTokenPrices(
        uint64 observationPeriod,
        uint128 minOracleTokenLiquidity,
        address[] memory baseTokens
    ) public returns (uint256 blockTimestamp, uint256 baseFee, uint256[] memory prices) {
        blockTimestamp = block.timestamp;
        baseFee = block.basefee;

        (address oracleToken, PeriodAverage[] memory results) = getOracleTokenAverages(observationPeriod, baseTokens);

        prices = new uint256[](results.length);

        // now we populate the resulting prices it if we have all the necessary data
        uint256 maxForNative = getMaximumObservationPeriod(NATIVE_TOKEN_ADDRESS);
        if (maxForNative >= observationPeriod) {
            PeriodAverage memory nativeAverage = getAveragesOverPeriod(
                NATIVE_TOKEN_ADDRESS, oracleToken, uint64(blockTimestamp - observationPeriod), uint64(blockTimestamp)
            );

            if (nativeAverage.liquidity > minOracleTokenLiquidity) {
                uint256 sqrtRatioOracleTokenPerNativeToken = tickToSqrtRatio(nativeAverage.tick);
                for (uint256 i = 0; i < results.length; i++) {
                    if (results[i].liquidity > minOracleTokenLiquidity) {
                        uint256 sqrtRatioOracleTokenPerBaseToken = tickToSqrtRatio(results[i].tick);
                        // we want native token per base token, so we divide by oracle token / native token
                        uint256 sqrtRatio = FixedPointMathLib.fullMulDiv(
                            sqrtRatioOracleTokenPerBaseToken, uint256(1) << 128, sqrtRatioOracleTokenPerNativeToken
                        );
                        prices[i] = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);
                    }
                }
            }
        }
    }
}
