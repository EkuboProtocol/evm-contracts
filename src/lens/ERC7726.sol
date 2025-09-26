// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IOracle} from "../interfaces/extensions/IOracle.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";

address constant IERC7726_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant IERC7726_BTC_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
address constant IERC7726_USD_ADDRESS = address(840);

/// @title ERC7726
/// @notice Standard interface for price oracles
interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

/// @title Ekubo ERC7726 Oracle Implementation
/// @dev Implements the standard Oracle interface using data from the Ekubo Protocol Oracle extension
contract ERC7726 is IERC7726 {
    /// @notice The oracle contract that is queried for prices
    IOracle public immutable ORACLE;

    /// @notice The token whose price we query to represent USD
    address public immutable USD_PROXY_TOKEN;
    /// @notice The token whose price we query to represent BTC
    address public immutable BTC_PROXY_TOKEN;

    /// @notice The amount of time over which we query to get the average price
    uint32 public immutable TWAP_DURATION;

    constructor(IOracle oracle, address usdProxyToken, address btcProxyToken, uint32 twapDuration) {
        ORACLE = oracle;
        USD_PROXY_TOKEN = usdProxyToken;
        BTC_PROXY_TOKEN = btcProxyToken;
        TWAP_DURATION = twapDuration;
    }

    /// @dev Returns the average tick for the given pair over the last `twapDuration` seconds
    /// @dev The returned tick always represents the price in terms of quoteToken / baseToken
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

    /// @dev Because the oracle only knows about tokens, except for the native token ETH,
    ///      we need to use tokens in place of USD, BTC. Since ETH is used directly in the protocol,
    ///      an ETH proxy token is not needed, but Ekubo Protocol uses address 0 to represent ETH.
    function normalizeAddress(address addr) private view returns (address) {
        if (addr == IERC7726_ETH_ADDRESS) {
            return NATIVE_TOKEN_ADDRESS;
        }
        if (addr == IERC7726_BTC_ADDRESS) {
            return BTC_PROXY_TOKEN;
        }
        if (addr == IERC7726_USD_ADDRESS) {
            return USD_PROXY_TOKEN;
        }

        return addr;
    }

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        int32 tick = getAverageTick({baseToken: normalizeAddress(base), quoteToken: normalizeAddress(quote)});

        uint256 sqrtRatio = tickToSqrtRatio(tick).toFixed();

        uint256 ratio = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);

        quoteAmount = FixedPointMathLib.fullMulDivN(baseAmount, ratio, 128);
    }
}
