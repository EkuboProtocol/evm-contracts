// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {Position} from "../../src/types/position.sol";

contract PositionTest is Test {
    function test_fees(Position memory p, FeesPerLiquidity memory insideLast) public pure {
        // never reverts
        (uint128 fee0, uint128 fee1) = p.fees(insideLast);
        if (p.liquidity == 0) {
            assertEq(fee0, 0);
            assertEq(fee1, 0);
        }
    }

    function test_fees_examples() public pure {
        (uint128 fee0, uint128 fee1) = Position({
            liquidity: 100,
            extraData: bytes16(0),
            feesPerLiquidityInsideLast: FeesPerLiquidity({value0: 1 << 128, value1: 2 << 128})
        }).fees(FeesPerLiquidity({value0: 3 << 128, value1: 5 << 128}));
        assertEq(fee0, 200);
        assertEq(fee1, 300);

        (fee0, fee1) = Position({
            liquidity: 150,
            extraData: bytes16(0),
            feesPerLiquidityInsideLast: FeesPerLiquidity({value0: 3 << 127, value1: 2 << 127})
        }).fees(FeesPerLiquidity({value0: 3 << 128, value1: 5 << 128}));
        assertEq(fee0, 225);
        assertEq(fee1, 600);

        // rounds down
        (fee0, fee1) = Position({
            liquidity: 100,
            extraData: bytes16(0),
            feesPerLiquidityInsideLast: FeesPerLiquidity({value0: 0, value1: 0})
        }).fees(FeesPerLiquidity({value0: type(uint128).max, value1: type(uint128).max}));
        assertEq(fee0, 99);
        assertEq(fee1, 99);
    }
}
