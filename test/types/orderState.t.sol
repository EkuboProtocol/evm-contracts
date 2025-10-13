// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {OrderState, createOrderState} from "../../src/types/orderState.sol";

contract OrderStateTest is Test {
    function test_conversionToAndFrom(OrderState state) public pure {
        assertEq(
            OrderState.unwrap(
                createOrderState({
                    _lastUpdateTime: state.lastUpdateTime(),
                    _saleRate: state.saleRate(),
                    _amountSold: state.amountSold()
                })
            ),
            OrderState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(uint32 lastUpdateTime, uint112 saleRate, uint112 amountSold) public pure {
        OrderState state =
            createOrderState({_lastUpdateTime: lastUpdateTime, _saleRate: saleRate, _amountSold: amountSold});
        assertEq(state.lastUpdateTime(), lastUpdateTime);
        assertEq(state.saleRate(), saleRate);
        assertEq(state.amountSold(), amountSold);
    }

    function test_conversionFromAndToDirtyBits(bytes32 timeDirty, bytes32 saleRateDirty, bytes32 amountSoldDirty)
        public
        pure
    {
        uint32 lastUpdateTime;
        uint112 saleRate;
        uint112 amountSold;

        assembly ("memory-safe") {
            lastUpdateTime := timeDirty
            saleRate := saleRateDirty
            amountSold := amountSoldDirty
        }

        OrderState state =
            createOrderState({_lastUpdateTime: lastUpdateTime, _saleRate: saleRate, _amountSold: amountSold});
        assertEq(state.lastUpdateTime(), lastUpdateTime, "lastUpdateTime");
        assertEq(state.saleRate(), saleRate, "saleRate");
        assertEq(state.amountSold(), amountSold, "amountSold");
    }

    function test_parse(uint32 lastUpdateTime, uint112 saleRate, uint112 amountSold) public pure {
        OrderState state =
            createOrderState({_lastUpdateTime: lastUpdateTime, _saleRate: saleRate, _amountSold: amountSold});

        (uint32 parsedTime, uint112 parsedRate, uint112 parsedAmount) = state.parse();

        assertEq(parsedTime, lastUpdateTime, "parsed lastUpdateTime");
        assertEq(parsedRate, saleRate, "parsed saleRate");
        assertEq(parsedAmount, amountSold, "parsed amountSold");
    }

    function test_individualAccessors(uint32 lastUpdateTime, uint112 saleRate, uint112 amountSold) public pure {
        OrderState state =
            createOrderState({_lastUpdateTime: lastUpdateTime, _saleRate: saleRate, _amountSold: amountSold});

        assertEq(state.lastUpdateTime(), lastUpdateTime, "individual lastUpdateTime");
        assertEq(state.saleRate(), saleRate, "individual saleRate");
        assertEq(state.amountSold(), amountSold, "individual amountSold");
    }
}
