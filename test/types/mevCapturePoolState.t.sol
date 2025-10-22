// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {MEVCapturePoolState, createMEVCapturePoolState} from "../../src/types/mevCapturePoolState.sol";

contract MEVCapturePoolStateTest is Test {
    function test_conversionToAndFrom(MEVCapturePoolState state) public pure {
        // MEVCapturePoolState only uses the top 32 and bottom lower 32 bits
        bytes32 maskedState;
        assembly ("memory-safe") {
            // Keep only the top and bottom 32 bits
            maskedState := or(shl(224, shr(224, state)), shr(224, shl(224, state)))
        }

        assertEq(
            MEVCapturePoolState.unwrap(
                createMEVCapturePoolState({_lastUpdateTime: state.lastUpdateTime(), _tickLast: state.tickLast()})
            ),
            maskedState
        );
    }

    function test_conversionFromAndTo(uint32 lastUpdateTime, int32 tickLast) public pure {
        MEVCapturePoolState state = createMEVCapturePoolState({_lastUpdateTime: lastUpdateTime, _tickLast: tickLast});
        assertEq(state.lastUpdateTime(), lastUpdateTime);
        assertEq(state.tickLast(), tickLast);
    }

    function test_conversionFromAndToDirtyBits(bytes32 lastUpdateTimeDirty, bytes32 tickLastDirty) public pure {
        uint32 lastUpdateTime;
        int32 tickLast;

        assembly ("memory-safe") {
            lastUpdateTime := lastUpdateTimeDirty
            tickLast := tickLastDirty
        }

        MEVCapturePoolState state = createMEVCapturePoolState({_lastUpdateTime: lastUpdateTime, _tickLast: tickLast});
        assertEq(state.lastUpdateTime(), lastUpdateTime, "lastUpdateTime");
        assertEq(state.tickLast(), tickLast, "tickLast");
    }
}
