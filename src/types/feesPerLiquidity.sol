// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// The total fees per liquidity for each token.
// Since these are always read together we put them in a struct, even though they cannot be packed.
struct FeesPerLiquidity {
    uint256 value0;
    uint256 value1;
}

using {sub} for FeesPerLiquidity global;

function sub(FeesPerLiquidity memory a, FeesPerLiquidity memory b) pure returns (FeesPerLiquidity memory result) {
    assembly ("memory-safe") {
        mstore(result, sub(mload(a), mload(b)))
        mstore(add(result, 32), sub(mload(add(a, 32)), mload(add(b, 32))))
    }
}

function feesPerLiquidityFromAmounts(uint128 amount0, uint128 amount1, uint128 liquidity)
    pure
    returns (FeesPerLiquidity memory result)
{
    assembly ("memory-safe") {
        mstore(result, div(shl(128, amount0), liquidity))
        mstore(add(result, 32), div(shl(128, amount1), liquidity))
    }
}
