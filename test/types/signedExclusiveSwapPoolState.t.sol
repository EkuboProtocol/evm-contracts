// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    SignedExclusiveSwapPoolState,
    createSignedExclusiveSwapPoolState,
    controller,
    lastUpdateTime,
    withLastUpdateTime,
    withController
} from "../../src/types/signedExclusiveSwapPoolState.sol";
import {ControllerAddress, isEoa} from "../../src/types/controllerAddress.sol";

contract SignedExclusiveSwapPoolStateTest is Test {
    function test_pack_unpack(address _controller, uint32 _lastUpdateTime) public pure {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState(controllerAddress, _lastUpdateTime);

        assertEq(ControllerAddress.unwrap(controller(state)), _controller);
        assertEq(lastUpdateTime(state), _lastUpdateTime);
        assertEq(isEoa(controller(state)), uint160(_controller) >> 159 == 0);
    }

    function test_withLastUpdateTime(address _controller, uint32 _lastUpdateTime, uint32 nextTime) public pure {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState(controllerAddress, _lastUpdateTime);
        SignedExclusiveSwapPoolState updated = withLastUpdateTime(state, nextTime);

        assertEq(ControllerAddress.unwrap(controller(updated)), _controller);
        assertEq(isEoa(controller(updated)), uint160(_controller) >> 159 == 0);
        assertEq(lastUpdateTime(updated), nextTime);
    }

    function test_withController(address _controller, uint32 _lastUpdateTime, address nextController) public pure {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        ControllerAddress nextControllerAddress = ControllerAddress.wrap(nextController);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState(controllerAddress, _lastUpdateTime);
        SignedExclusiveSwapPoolState updated = withController(state, nextControllerAddress);

        assertEq(ControllerAddress.unwrap(controller(updated)), nextController);
        assertEq(isEoa(controller(updated)), uint160(nextController) >> 159 == 0);
        assertEq(lastUpdateTime(updated), _lastUpdateTime);
    }
}
