// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FeesPerLiquidity} from "./feesPerLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Position Type
// Represents a liquidity position in a pool
// Contains the position's liquidity amount, time tracking, and fee tracking information

/// @notice A liquidity position in a pool
/// @dev Tracks liquidity amount, time inside, and fees per liquidity for fee calculation
struct Position {
    /// @notice Amount of liquidity in the position
    uint128 liquidity;
    /// @notice Timestamp when the position was last inside the price range
    /// @dev Used to calculate how long the position has been active
    uint64 secondsInsideLast;
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
    uint128 liquidity;
    uint256 difference0;
    uint256 difference1;
    assembly ("memory-safe") {
        // In memory, struct members are NOT packed - each starts at a 32-byte boundary
        // Offset 0x00: liquidity (uint128)
        // Offset 0x20: secondsInsideLast (uint64)
        // Offset 0x40: feesPerLiquidityInsideLast.value0 (uint256)
        // Offset 0x60: feesPerLiquidityInsideLast.value1 (uint256)
        liquidity := mload(position)
        let positionFpl0 := mload(add(position, 0x40))
        let positionFpl1 := mload(add(position, 0x60))
        difference0 := sub(mload(feesPerLiquidityInside), positionFpl0)
        difference1 := sub(mload(add(feesPerLiquidityInside, 0x20)), positionFpl1)
    }

    return (
        uint128(FixedPointMathLib.fullMulDivN(difference0, liquidity, 128)),
        uint128(FixedPointMathLib.fullMulDivN(difference1, liquidity, 128))
    );
}
