// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeesPerLiquidity, feesPerLiquidityFromAmounts} from "../../src/types/feesPerLiquidity.sol";

contract FeesPerLiquidityTest is Test {
    function test_sub(FeesPerLiquidity memory a, FeesPerLiquidity memory b) public pure {
        FeesPerLiquidity memory c = a.sub(b);
        unchecked {
            assertEq(c.value0, a.value0 - b.value0);
            assertEq(c.value1, a.value1 - b.value1);
        }
    }

    function test_feesPerLiquidityFromAmounts(uint128 amount0, uint128 amount1, uint128 liquidity) public pure {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        FeesPerLiquidity memory c = feesPerLiquidityFromAmounts(amount0, amount1, liquidity);
        unchecked {
            assertEq(c.value0, (uint256(amount0) << 128) / liquidity, "amount0");
            assertEq(c.value1, (uint256(amount1) << 128) / liquidity, "amount1");
        }
    }

    function test_feesPerLiquidityFromAmounts_zero_liquidity(uint128 amount0, uint128 amount1) public pure {
        FeesPerLiquidity memory c = feesPerLiquidityFromAmounts({amount0: amount0, amount1: amount1, liquidity: 0});
        unchecked {
            assertEq(c.value0, 0, "amount0");
            assertEq(c.value1, 0, "amount1");
        }
    }
}
