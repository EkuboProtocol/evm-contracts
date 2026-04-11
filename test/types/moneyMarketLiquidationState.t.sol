// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    MoneyMarketLiquidationState,
    createMoneyMarketLiquidationState
} from "../../src/types/moneyMarketLiquidationState.sol";

contract MoneyMarketLiquidationStateTest is Test {
    function test_conversionToAndFrom(MoneyMarketLiquidationState state) public pure {
        MoneyMarketLiquidationState roundtrip = createMoneyMarketLiquidationState({
            _activeOrderEndTime: state.activeOrderEndTime(), _liquidationAmount: state.liquidationAmount()
        });
        assertEq(roundtrip.activeOrderEndTime(), state.activeOrderEndTime());
        assertEq(roundtrip.liquidationAmount(), state.liquidationAmount());
    }

    function test_conversionFromAndTo(uint64 endTime, uint128 amount) public pure {
        MoneyMarketLiquidationState state =
            createMoneyMarketLiquidationState({_activeOrderEndTime: endTime, _liquidationAmount: amount});
        assertEq(state.activeOrderEndTime(), endTime);
        assertEq(state.liquidationAmount(), amount);
    }

    function test_parse(uint64 endTime, uint128 amount) public pure {
        MoneyMarketLiquidationState state =
            createMoneyMarketLiquidationState({_activeOrderEndTime: endTime, _liquidationAmount: amount});
        (uint64 parsedEndTime, uint128 parsedAmount) = state.parse();
        assertEq(parsedEndTime, endTime);
        assertEq(parsedAmount, amount);
    }
}
