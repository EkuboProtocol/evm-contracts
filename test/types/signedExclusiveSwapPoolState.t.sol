// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    SignedExclusiveSwapPoolState,
    createSignedExclusiveSwapPoolState,
    controller,
    lastUpdateTime,
    controllerIsEoa,
    withLastUpdateTime,
    withController
} from "../../src/types/signedExclusiveSwapPoolState.sol";

contract SignedExclusiveSwapPoolStateTest is Test {
    function test_pack_unpack(address _controller, uint32 _lastUpdateTime, bool _controllerIsEoa) public pure {
        SignedExclusiveSwapPoolState state =
            createSignedExclusiveSwapPoolState(_controller, _lastUpdateTime, _controllerIsEoa);

        assertEq(controller(state), _controller);
        assertEq(lastUpdateTime(state), _lastUpdateTime);
        assertEq(controllerIsEoa(state), _controllerIsEoa);
    }

    function test_withLastUpdateTime(
        address _controller,
        uint32 _lastUpdateTime,
        bool _controllerIsEoa,
        uint32 nextTime
    ) public pure {
        SignedExclusiveSwapPoolState state =
            createSignedExclusiveSwapPoolState(_controller, _lastUpdateTime, _controllerIsEoa);
        SignedExclusiveSwapPoolState updated = withLastUpdateTime(state, nextTime);

        assertEq(controller(updated), _controller);
        assertEq(controllerIsEoa(updated), _controllerIsEoa);
        assertEq(lastUpdateTime(updated), nextTime);
    }

    function test_withController(
        address _controller,
        uint32 _lastUpdateTime,
        bool _controllerIsEoa,
        address nextController,
        bool nextControllerIsEoa
    ) public pure {
        SignedExclusiveSwapPoolState state =
            createSignedExclusiveSwapPoolState(_controller, _lastUpdateTime, _controllerIsEoa);
        SignedExclusiveSwapPoolState updated = withController(state, nextController, nextControllerIsEoa);

        assertEq(controller(updated), nextController);
        assertEq(controllerIsEoa(updated), nextControllerIsEoa);
        assertEq(lastUpdateTime(updated), _lastUpdateTime);
    }
}
