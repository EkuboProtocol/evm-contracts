// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";

contract FeesPerLiquidityTest is Test {
    function test_sub(FeesPerLiquidity memory a, FeesPerLiquidity memory b) public pure {
        FeesPerLiquidity memory c = a.sub(b);
        unchecked {
            assertEq(c.value0, a.value0 - b.value0);
            assertEq(c.value1, a.value1 - b.value1);
        }
    }
}
