// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

struct Position {
    uint128 liquidity;
    FeesPerLiquidity feesPerLiquidityInsideLast;
}

using {fees} for Position global;

/// @dev Returns the fee amounts of token0 and token1 owed to a position based on the given fees per liquidity inside snapshot
///      Note if the computed fees overflows the uint128 type, it will return only the lower 128 bits. It is assumed that accumulated
///      fees will never exceed type(uint128).max.
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
