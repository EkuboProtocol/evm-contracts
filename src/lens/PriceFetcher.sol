// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Oracle} from "../extensions/Oracle.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract PriceFetcher {
    Oracle public immutable oracle;

    constructor(Oracle _oracle) {
        oracle = _oracle;
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

    function getPricesInOracleToken(uint64 observationPeriod, address[] memory baseTokens)
        external
        returns (address oracleToken, Result[] memory results)
    {
        oracleToken = oracle.oracleToken();
        results = new Result[](baseTokens.length);
        unchecked {
            for (uint256 i = 0; i < baseTokens.length; i++) {
                address token = baseTokens[i];
                if (oracleToken == token) {
                    results[i] = Result(1 << 128, type(uint128).max);
                } else {
                    uint256 maxPeriod = getMaximumObservationPeriod(token);

                    if (maxPeriod >= observationPeriod) {
                        (uint128 liquidity, int32 tick) = oracle.getAveragesOverPeriod(
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
}
