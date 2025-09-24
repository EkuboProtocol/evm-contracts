// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {TwammPoolState, createTwammPoolState} from "../../src/types/twammPoolState.sol";

contract TwammPoolStateTest is Test {
    function test_conversionToAndFrom(TwammPoolState state) public pure {
        assertEq(
            TwammPoolState.unwrap(
                createTwammPoolState({
                    _lastVirtualOrderExecutionTime: state.lastVirtualOrderExecutionTime(),
                    _saleRateToken0: state.saleRateToken0(),
                    _saleRateToken1: state.saleRateToken1()
                })
            ),
            TwammPoolState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(
        uint32 lastVirtualOrderExecutionTime,
        uint112 saleRateToken0,
        uint112 saleRateToken1
    ) public pure {
        TwammPoolState state = createTwammPoolState({
            _lastVirtualOrderExecutionTime: lastVirtualOrderExecutionTime,
            _saleRateToken0: saleRateToken0,
            _saleRateToken1: saleRateToken1
        });
        assertEq(state.lastVirtualOrderExecutionTime(), lastVirtualOrderExecutionTime);
        assertEq(state.saleRateToken0(), saleRateToken0);
        assertEq(state.saleRateToken1(), saleRateToken1);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 lastVirtualOrderExecutionTimeDirty,
        bytes32 saleRateToken0Dirty,
        bytes32 saleRateToken1Dirty
    ) public pure {
        uint32 lastVirtualOrderExecutionTime;
        uint112 saleRateToken0;
        uint112 saleRateToken1;

        assembly ("memory-safe") {
            lastVirtualOrderExecutionTime := lastVirtualOrderExecutionTimeDirty
            saleRateToken0 := saleRateToken0Dirty
            saleRateToken1 := saleRateToken1Dirty
        }

        TwammPoolState state = createTwammPoolState({
            _lastVirtualOrderExecutionTime: lastVirtualOrderExecutionTime,
            _saleRateToken0: saleRateToken0,
            _saleRateToken1: saleRateToken1
        });
        assertEq(state.lastVirtualOrderExecutionTime(), lastVirtualOrderExecutionTime, "lastVirtualOrderExecutionTime");
        assertEq(state.saleRateToken0(), saleRateToken0, "saleRateToken0");
        assertEq(state.saleRateToken1(), saleRateToken1, "saleRateToken1");
    }

    function test_parse(uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1)
        public
        pure
    {
        TwammPoolState state = createTwammPoolState({
            _lastVirtualOrderExecutionTime: lastVirtualOrderExecutionTime,
            _saleRateToken0: saleRateToken0,
            _saleRateToken1: saleRateToken1
        });

        (uint32 parsedTime, uint112 parsedRate0, uint112 parsedRate1) = state.parse();

        assertEq(parsedTime, lastVirtualOrderExecutionTime, "parsed lastVirtualOrderExecutionTime");
        assertEq(parsedRate0, saleRateToken0, "parsed saleRateToken0");
        assertEq(parsedRate1, saleRateToken1, "parsed saleRateToken1");
    }
}
