// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ve33GlobalEmissionState, createVe33GlobalEmissionState} from "../../src/types/ve33GlobalEmissionState.sol";

contract Ve33GlobalEmissionStateTest is Test {
    function test_conversionToAndFrom(Ve33GlobalEmissionState state) public pure {
        (uint160 rate, uint32 lastAccrued) = state.parse();
        Ve33GlobalEmissionState recreated = createVe33GlobalEmissionState(rate, lastAccrued);

        assertEq(recreated.emissionRate(), state.emissionRate(), "emissionRate");
        assertEq(recreated.lastAccrued(), state.lastAccrued(), "lastAccrued");
    }

    function test_conversionFromAndTo(uint160 emissionRate, uint32 lastAccrued) public pure {
        Ve33GlobalEmissionState state = createVe33GlobalEmissionState(emissionRate, lastAccrued);
        assertEq(state.emissionRate(), emissionRate);
        assertEq(state.lastAccrued(), lastAccrued);

        (uint160 parsedEmissionRate, uint32 parsedLastAccrued) = state.parse();
        assertEq(parsedEmissionRate, emissionRate);
        assertEq(parsedLastAccrued, lastAccrued);
    }

    function test_conversionFromAndToDirtyBits(bytes32 emissionRateDirty, bytes32 lastAccruedDirty) public pure {
        uint160 emissionRate;
        uint32 lastAccrued;

        assembly ("memory-safe") {
            emissionRate := emissionRateDirty
            lastAccrued := lastAccruedDirty
        }

        Ve33GlobalEmissionState state = createVe33GlobalEmissionState(emissionRate, lastAccrued);
        assertEq(state.emissionRate(), emissionRate, "emissionRate");
        assertEq(state.lastAccrued(), lastAccrued, "lastAccrued");
    }

    function test_realEmissionTimeAtOrBeforeNow() public {
        vm.warp((uint256(3) << 32) + 1234);

        Ve33GlobalEmissionState state = createVe33GlobalEmissionState(0, 1000);

        assertEq(state.realEmissionTimeAtOrBeforeNow(), (uint256(3) << 32) + 1000);
    }
}
