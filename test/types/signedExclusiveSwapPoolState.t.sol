// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    SignedExclusiveSwapPoolState,
    createSignedExclusiveSwapPoolState,
    controller,
    lastUpdateTime,
    withLastUpdateTime,
    withController,
    ownerFee,
    withOwnerFee
} from "../../src/types/signedExclusiveSwapPoolState.sol";
import {ControllerAddress, isEoa} from "../../src/types/controllerAddress.sol";

contract SignedExclusiveSwapPoolStateTest is Test {
    function test_pack_unpack(address _controller, uint32 _lastUpdateTime, uint64 _ownerFee) public pure {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState({
            _controller: controllerAddress, _lastUpdateTime: _lastUpdateTime, _ownerFee: _ownerFee
        });

        assertEq(ControllerAddress.unwrap(controller(state)), _controller);
        assertEq(lastUpdateTime(state), _lastUpdateTime);
        assertEq(ownerFee(state), _ownerFee);
        assertEq(isEoa(controller(state)), uint160(_controller) >> 159 == 0);
    }

    function test_withLastUpdateTime(address _controller, uint32 _lastUpdateTime, uint32 nextTime, uint64 _ownerFee)
        public
        pure
    {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState({
            _controller: controllerAddress, _lastUpdateTime: _lastUpdateTime, _ownerFee: _ownerFee
        });
        SignedExclusiveSwapPoolState updated = withLastUpdateTime(state, nextTime);

        assertEq(ControllerAddress.unwrap(controller(updated)), _controller);
        assertEq(isEoa(controller(updated)), uint160(_controller) >> 159 == 0);
        assertEq(lastUpdateTime(updated), nextTime);
        assertEq(ownerFee(updated), _ownerFee);
    }

    function test_withController(address _controller, uint32 _lastUpdateTime, address nextController, uint64 _ownerFee)
        public
        pure
    {
        ControllerAddress controllerAddress = ControllerAddress.wrap(_controller);
        ControllerAddress nextControllerAddress = ControllerAddress.wrap(nextController);
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState({
            _controller: controllerAddress, _lastUpdateTime: _lastUpdateTime, _ownerFee: _ownerFee
        });
        SignedExclusiveSwapPoolState updated = withController(state, nextControllerAddress);

        assertEq(ControllerAddress.unwrap(controller(updated)), nextController);
        assertEq(isEoa(controller(updated)), uint160(nextController) >> 159 == 0);
        assertEq(lastUpdateTime(updated), _lastUpdateTime);
        assertEq(ownerFee(updated), _ownerFee);
    }

    function test_withOwnerFee(address _controller, uint32 time, uint64 fee, uint64 nextFee) public pure {
        SignedExclusiveSwapPoolState state = createSignedExclusiveSwapPoolState({
            _controller: ControllerAddress.wrap(_controller), _lastUpdateTime: time, _ownerFee: fee
        });
        SignedExclusiveSwapPoolState updated = withOwnerFee(state, nextFee);
        assertEq(ControllerAddress.unwrap(controller(updated)), _controller);
        assertEq(lastUpdateTime(updated), time);
        assertEq(ownerFee(updated), nextFee);
    }
}
