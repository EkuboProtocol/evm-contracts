// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Position Type
// Represents a liquidity position in a pool
// Contains the position's liquidity amount and fee tracking information

/// @notice A liquidity position in a pool
/// @dev Tracks both the liquidity amount and the last known fees per liquidity for fee calculation
struct Position {
    /// @notice Amount of liquidity in the position
    uint128 liquidity;
    /// @notice Snapshot of fees per liquidity when the position was last updated
    /// @dev Used to calculate fees owed to the position holder
    FeesPerLiquidity feesPerLiquidityInsideLast;
}

using {fees} for Position global;

/// @notice Calculates the fees owed to a position
/// @dev Returns the fee amounts of token0 and token1 owed to a position based on the given fees per liquidity inside snapshot
///      Note: if the computed fees overflow the uint128 type, it will return only the lower 128 bits. It is assumed that accumulated
///      fees will never exceed type(uint128).max.
/// @param position The position to calculate fees for
/// @param feesPerLiquidityInside Current fees per liquidity inside the position's bounds
/// @return Amount of token0 fees owed
/// @return Amount of token1 fees owed
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
