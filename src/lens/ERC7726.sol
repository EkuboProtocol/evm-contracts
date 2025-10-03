// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IOracle} from "../interfaces/extensions/IOracle.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";

// Standard ERC-7726 address representing ETH in price queries
// This is the canonical address defined in ERC-7726 for representing Ethereum
address constant IERC7726_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// Standard ERC-7726 address representing BTC in price queries
// This is the canonical address defined in ERC-7726 for representing Bitcoin
address constant IERC7726_BTC_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

// Standard ERC-7726 address representing USD in price queries
// This is the canonical address defined in ERC-7726 for representing US Dollar (ISO 4217 code 840)
address constant IERC7726_USD_ADDRESS = address(840);

/// @title ERC-7726 Standard Oracle Interface
/// @notice Defines the standard interface for price oracles as specified in ERC-7726
/// @dev This interface provides a unified way to query asset prices across different oracle implementations
interface IERC7726 {
    /// @notice Returns the quote amount for a given base amount and asset pair
    /// @dev Implementations should handle standard ERC-7726 addresses (ETH, BTC, USD) appropriately
    /// @param baseAmount The amount of the base asset to convert
    /// @param base The address of the base asset (asset being converted from)
    /// @param quote The address of the quote asset (asset being converted to)
    /// @return quoteAmount The equivalent amount in the quote asset
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

/// @title Ekubo ERC-7726 Oracle Implementation
/// @notice Implements the ERC-7726 standard oracle interface using time-weighted average prices from Ekubo Protocol
/// @dev This contract provides manipulation-resistant price quotes by leveraging Ekubo's Oracle extension
///      which records price and liquidity data into accumulators. The oracle supports direct queries for
///      tokens paired with ETH, and cross-pair calculations for other token pairs.
/// @author Ekubo Protocol
contract ERC7726 is IERC7726 {
    /// @notice Thrown when an invalid TWAP duration is provided
    error InvalidTwapDuration();

    /// @notice The Ekubo Oracle extension contract used for price data
    IOracle public immutable ORACLE;

    /// @notice The address of the token to represent ETH, or NATIVE_TOKEN_ADDRESS if ETH is the native token on the chain
    address public immutable ETH_PROXY_TOKEN;

    /// @notice The ERC-20 token used as a proxy to represent USD in price calculations
    address public immutable USD_PROXY_TOKEN;

    /// @notice The ERC-20 token used as a proxy to represent BTC in price calculations
    /// @dev Since the oracle only tracks token pairs with ETH, we use a BTC-pegged token (e.g., WBTC) as a proxy
    address public immutable BTC_PROXY_TOKEN;

    /// @notice The time window in seconds over which to calculate time-weighted average prices
    /// @dev Longer durations provide more manipulation resistance but less price responsiveness
    uint32 public immutable TWAP_DURATION;

    /// @notice Constructs the ERC-7726 oracle with the specified parameters
    /// @dev Validates all input parameters to ensure proper oracle functionality
    /// @param oracle The Ekubo Oracle extension contract address
    /// @param usdProxyToken The token address to use as a USD proxy (e.g., USDC)
    /// @param btcProxyToken The token address to use as a BTC proxy (e.g., WBTC)
    /// @param twapDuration The time window in seconds for TWAP calculations (must be > 0)
    constructor(
        IOracle oracle,
        address usdProxyToken,
        address btcProxyToken,
        address ethProxyToken,
        uint32 twapDuration
    ) {
        if (twapDuration == 0) revert InvalidTwapDuration();

        ORACLE = oracle;
        USD_PROXY_TOKEN = usdProxyToken;
        BTC_PROXY_TOKEN = btcProxyToken;
        ETH_PROXY_TOKEN = ethProxyToken;
        TWAP_DURATION = twapDuration;
    }

    /// @notice Calculates the time-weighted average tick for a token pair over the specified duration
    /// @dev The returned tick represents the logarithmic price ratio (quoteToken / baseToken)
    ///      For pairs not directly tracked by the oracle, this function performs cross-pair calculations
    ///      using ETH as an intermediary asset
    /// @param baseToken The base token address (denominator in the price ratio)
    /// @param quoteToken The quote token address (numerator in the price ratio)
    /// @return tick The average tick over the TWAP duration, bounded by MIN_TICK and MAX_TICK
    function getAverageTick(address baseToken, address quoteToken) private view returns (int32 tick) {
        unchecked {
            bool baseIsOracleToken = baseToken == NATIVE_TOKEN_ADDRESS;
            if (baseIsOracleToken || quoteToken == NATIVE_TOKEN_ADDRESS) {
                (int32 tickSign, address otherToken) =
                    baseIsOracleToken ? (int32(1), quoteToken) : (int32(-1), baseToken);

                (, int64 tickCumulativeStart) = ORACLE.extrapolateSnapshot(otherToken, block.timestamp - TWAP_DURATION);
                (, int64 tickCumulativeEnd) = ORACLE.extrapolateSnapshot(otherToken, block.timestamp);

                return tickSign * int32((tickCumulativeEnd - tickCumulativeStart) / int64(uint64(TWAP_DURATION)));
            } else {
                int32 baseTick = getAverageTick(NATIVE_TOKEN_ADDRESS, baseToken);
                int32 quoteTick = getAverageTick(NATIVE_TOKEN_ADDRESS, quoteToken);

                return int32(
                    FixedPointMathLib.min(MAX_TICK, FixedPointMathLib.max(MIN_TICK, int256(quoteTick - baseTick)))
                );
            }
        }
    }

    /// @notice Converts ERC-7726 standard addresses to their corresponding token addresses
    /// @dev The Ekubo Oracle only tracks token pairs with the native token (represented as address(0) internally).
    ///      This function maps standard ERC-7726 addresses to actual token addresses:
    ///      - ETH address maps to ETH_PROXY_TOKEN (e.g. NATIVE_TOKEN_ADDRESS)
    ///      - BTC address maps to BTC_PROXY_TOKEN (e.g., WBTC)
    ///      - USD address maps to USD_PROXY_TOKEN (e.g., USDC)
    ///      - All other addresses pass through unchanged
    /// @param addr The input address (may be an ERC-7726 standard address or regular token address)
    /// @return The normalized token address for use with the Ekubo Oracle
    function normalizeAddress(address addr) private view returns (address) {
        if (addr == IERC7726_ETH_ADDRESS) {
            return ETH_PROXY_TOKEN;
        }
        if (addr == IERC7726_BTC_ADDRESS) {
            return BTC_PROXY_TOKEN;
        }
        if (addr == IERC7726_USD_ADDRESS) {
            return USD_PROXY_TOKEN;
        }

        return addr;
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        address normalizedBase = normalizeAddress(base);
        address normalizedQuote = normalizeAddress(quote);

        // Short-circuit same-token quotes to avoid unnecessary oracle calls and math
        if (normalizedBase == normalizedQuote) {
            return baseAmount;
        }

        int32 tick = getAverageTick({baseToken: normalizedBase, quoteToken: normalizedQuote});

        uint256 sqrtRatio = tickToSqrtRatio(tick).toFixed();

        uint256 ratio = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);

        quoteAmount = FixedPointMathLib.fullMulDivN(baseAmount, ratio, 128);
    }
}
