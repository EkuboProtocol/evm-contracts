// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {VePoolFeeState, createVePoolFeeState} from "../../src/types/vePoolFeeState.sol";

contract VePoolFeeStateTest is Test {
    function test_conversionToAndFrom(VePoolFeeState state) public pure {
        assertEq(
            VePoolFeeState.unwrap(
                createVePoolFeeState({feeWeightSum_: state.feeWeightSum(), swapFee_: state.swapFee()})
            ),
            VePoolFeeState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(uint192 feeWeightSum, uint64 swapFee) public pure {
        VePoolFeeState state = createVePoolFeeState({feeWeightSum_: feeWeightSum, swapFee_: swapFee});
        assertEq(state.feeWeightSum(), feeWeightSum);
        assertEq(state.swapFee(), swapFee);
    }

    function test_conversionFromAndToDirtyBits(bytes32 feeWeightSumDirty, bytes32 swapFeeDirty) public pure {
        uint192 feeWeightSum;
        uint64 swapFee;

        assembly ("memory-safe") {
            feeWeightSum := feeWeightSumDirty
            swapFee := swapFeeDirty
        }

        VePoolFeeState state = createVePoolFeeState({feeWeightSum_: feeWeightSum, swapFee_: swapFee});
        assertEq(state.feeWeightSum(), feeWeightSum, "feeWeightSum");
        assertEq(state.swapFee(), swapFee, "swapFee");
    }
}
