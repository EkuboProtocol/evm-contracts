// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

struct Position {
    uint128 liquidity;
    FeesPerLiquidity feesPerLiquidityInsideLast;
}

using {fees} for Position global;

function fees(Position memory position, FeesPerLiquidity memory feesPerLiquidityInside)
    pure
    returns (uint128, uint128)
{
    FeesPerLiquidity memory difference = feesPerLiquidityInside.sub(position.feesPerLiquidityInsideLast);

    return (
        uint128(FixedPointMathLib.fullMulDivN(difference.value0, position.liquidity, 128)),
        uint128(FixedPointMathLib.fullMulDivN(difference.value1, position.liquidity, 128))
    );
}
