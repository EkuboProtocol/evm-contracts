// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {Position} from "../../src/types/position.sol";

contract PositionTest is Test {
    function test_fees(Position memory p, FeesPerLiquidity memory insideLast) public pure {
        // never reverts
        p.fees(insideLast);
    }

    function test_fees_example() public pure {
        Position memory p = Position({
            liquidity: 100,
            feesPerLiquidityInsideLast: FeesPerLiquidity({value0: 1 << 128, value1: 2 << 128})
        });
        (uint128 fee0, uint128 fee1) = p.fees(FeesPerLiquidity({value0: 3 << 128, value1: 5 << 128}));
        assertEq(fee0, 200);
        assertEq(fee1, 300);
    }
}
