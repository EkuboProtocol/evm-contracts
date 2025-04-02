// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Oracle} from "../extensions/Oracle.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

address constant IERC7726_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant IERC7726_BTC_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
address constant IERC7726_USD_ADDRESS = address(840);

interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

/// @dev Implements the interface using Ekubo's Oracle extension
contract EkuboOracleERC7726 is IERC7726 {
    // the oracle stores all the snapshot data used to compute quotes
    Oracle public immutable oracle;

    // the token we query to represent USD
    address public immutable usdProxyToken;
    // the token we query to represent BTC
    address public immutable btcProxyToken;

    // the amount of time over which we query to get the price
    uint32 public immutable twapDuration;

    constructor(Oracle _oracle, address _usdProxyToken, address _btcProxyToken, uint32 _twapDuration) {
        oracle = _oracle;
        usdProxyToken = _usdProxyToken;
        btcProxyToken = _btcProxyToken;
        twapDuration = _twapDuration;
    }

    // The returned tick always represents the price in terms of quoteToken / baseToken
    function getAverageTick(address baseToken, address quoteToken) private view returns (int32 tick) {
        unchecked {
            bool baseIsOracleToken = baseToken == NATIVE_TOKEN_ADDRESS;
            if (baseIsOracleToken || quoteToken == NATIVE_TOKEN_ADDRESS) {
                (int32 tickSign, address otherToken) =
                    baseIsOracleToken ? (int32(1), quoteToken) : (int32(-1), baseToken);

                (, int64 tickCumulativeStart) = oracle.extrapolateSnapshot(otherToken, block.timestamp - twapDuration);
                (, int64 tickCumulativeEnd) = oracle.extrapolateSnapshot(otherToken, block.timestamp);

                return tickSign * int32((tickCumulativeEnd - tickCumulativeStart) / int64(uint64(twapDuration)));
            } else {
                int32 baseTick = getAverageTick(NATIVE_TOKEN_ADDRESS, baseToken);
                int32 quoteTick = getAverageTick(NATIVE_TOKEN_ADDRESS, quoteToken);

                return quoteTick - baseTick;
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
            return btcProxyToken;
        }
        if (addr == IERC7726_USD_ADDRESS) {
            return usdProxyToken;
        }

        return addr;
    }

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        quote = normalizeAddress(quote);

        int32 tick = getAverageTick(normalizeAddress(base), normalizeAddress(quote));

        uint256 sqrtRatio = tickToSqrtRatio(tick).toFixed();

        uint256 ratio = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);

        quoteAmount = FixedPointMathLib.fullMulDivN(baseAmount, ratio, 128);
    }
}
