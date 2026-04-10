// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    TWAMMRecoverableLiquidationState,
    createTWAMMRecoverableLiquidationState
} from "../../src/types/twammRecoverableLiquidationState.sol";

contract TWAMMRecoverableLiquidationStateTest is Test {
    function test_conversionToAndFrom(TWAMMRecoverableLiquidationState state) public pure {
        assertEq(
            TWAMMRecoverableLiquidationState.unwrap(
                createTWAMMRecoverableLiquidationState({
                    _activeOrderEndTime: state.activeOrderEndTime(), _active: state.active()
                })
            ),
            TWAMMRecoverableLiquidationState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(uint64 endTime, bool isActive) public pure {
        TWAMMRecoverableLiquidationState state =
            createTWAMMRecoverableLiquidationState({_activeOrderEndTime: endTime, _active: isActive});
        assertEq(state.activeOrderEndTime(), endTime);
        assertEq(state.active(), isActive);
    }

    function test_parse(uint64 endTime, bool isActive) public pure {
        TWAMMRecoverableLiquidationState state =
            createTWAMMRecoverableLiquidationState({_activeOrderEndTime: endTime, _active: isActive});
        (uint64 parsedEndTime, bool parsedActive) = state.parse();
        assertEq(parsedEndTime, endTime);
        assertEq(parsedActive, isActive);
    }
}
