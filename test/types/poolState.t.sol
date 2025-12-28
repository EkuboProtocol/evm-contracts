// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolState, createPoolState} from "../../src/types/poolState.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";

contract PoolStateTest is Test {
    function test_conversionToAndFrom(PoolState state) public pure {
        assertEq(
            PoolState.unwrap(
                createPoolState({_sqrtRatio: state.sqrtRatio(), _tick: state.tick(), _liquidity: state.liquidity()})
            ),
            PoolState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) public pure {
        PoolState state = createPoolState({_sqrtRatio: sqrtRatio, _tick: tick, _liquidity: liquidity});
        assertEq(SqrtRatio.unwrap(state.sqrtRatio()), SqrtRatio.unwrap(sqrtRatio));
        assertEq(state.tick(), tick);
        assertEq(state.liquidity(), liquidity);
    }

    function test_conversionFromAndToDirtyBits(bytes32 sqrtRatioDirty, bytes32 tickDirty, bytes32 liquidityDirty)
        public
        pure
    {
        SqrtRatio sqrtRatio;
        int32 tick;
        uint128 liquidity;

        assembly ("memory-safe") {
            sqrtRatio := sqrtRatioDirty
            tick := tickDirty
            liquidity := liquidityDirty
        }

        PoolState state = createPoolState({_sqrtRatio: sqrtRatio, _tick: tick, _liquidity: liquidity});
        assertEq(SqrtRatio.unwrap(state.sqrtRatio()), SqrtRatio.unwrap(sqrtRatio), "sqrtRatio");
        assertEq(state.tick(), tick, "tick");
        assertEq(state.liquidity(), liquidity, "liquidity");
    }
}
