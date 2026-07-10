// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {VePoolSwapFeeState, createVePoolSwapFeeState} from "../../src/types/vePoolSwapFeeState.sol";
import {Test} from "forge-std/Test.sol";

contract VePoolSwapFeeStateTest is Test {
    function test_conversionToAndFrom(VePoolSwapFeeState state) public pure {
        assertEq(
            VePoolSwapFeeState.unwrap(
                createVePoolSwapFeeState({totalWeight_: state.totalWeight(), swapFee_: state.swapFee()})
            ),
            VePoolSwapFeeState.unwrap(state)
                & bytes32(0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff)
        );
    }

    function test_conversionFromAndTo(uint128 totalWeight, uint64 swapFee) public pure {
        VePoolSwapFeeState state = createVePoolSwapFeeState({totalWeight_: totalWeight, swapFee_: swapFee});

        assertEq(state.totalWeight(), totalWeight);
        assertEq(state.swapFee(), swapFee);

        (uint128 parsedWeight, uint64 parsedFee) = state.parse();
        assertEq(parsedWeight, totalWeight);
        assertEq(parsedFee, swapFee);
    }

    function test_conversionFromAndToDirtyBits(bytes32 totalWeightDirty, bytes32 swapFeeDirty) public pure {
        uint128 totalWeight = uint128(uint256(totalWeightDirty));
        uint64 swapFee = uint64(uint256(swapFeeDirty));

        VePoolSwapFeeState state = createVePoolSwapFeeState({totalWeight_: totalWeight, swapFee_: swapFee});

        assertEq(state.totalWeight(), totalWeight, "totalWeight");
        assertEq(state.swapFee(), swapFee, "swapFee");
    }
}
