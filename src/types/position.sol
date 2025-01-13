// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

struct Position {
    uint128 liquidity;
    uint256 token0_fees_per_liquidity_inside_last;
    uint256 token1_fees_per_liquidity_inside_last;
}

using {fees} for Position global;

function fees(
    Position memory position,
    uint256 token0_fees_per_liquidity_inside,
    uint256 token1_fees_per_liquidity_inside
) returns (uint128, uint128) {
    unchecked {
        return (
            uint128(
                (token0_fees_per_liquidity_inside - position.token0_fees_per_liquidity_inside_last) * position.liquidity
            ),
            uint128(
                (token1_fees_per_liquidity_inside - position.token1_fees_per_liquidity_inside_last) * position.liquidity
            )
        );
    }
}
