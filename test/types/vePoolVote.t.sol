// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {VePoolVote, createVePoolVote} from "../../src/types/vePoolVote.sol";

contract VePoolVoteTest is Test {
    function test_conversionToAndFrom(VePoolVote vote) public pure {
        assertEq(
            VePoolVote.unwrap(
                createVePoolVote({weight_: vote.weight(), swapFee_: vote.swapFee(), timestamp_: vote.timestamp()})
            ),
            VePoolVote.unwrap(vote)
        );
    }

    function test_conversionFromAndTo(uint128 weight, uint64 swapFee, uint64 timestamp_) public pure {
        VePoolVote vote = createVePoolVote({weight_: weight, swapFee_: swapFee, timestamp_: timestamp_});
        assertEq(vote.weight(), weight);
        assertEq(vote.swapFee(), swapFee);
        assertEq(vote.timestamp(), timestamp_);
    }

    function test_conversionFromAndToDirtyBits(bytes32 weightDirty, bytes32 swapFeeDirty, bytes32 timestampDirty)
        public
        pure
    {
        uint128 weight;
        uint64 swapFee;
        uint64 timestamp_;

        assembly ("memory-safe") {
            weight := weightDirty
            swapFee := swapFeeDirty
            timestamp_ := timestampDirty
        }

        VePoolVote vote = createVePoolVote({weight_: weight, swapFee_: swapFee, timestamp_: timestamp_});
        assertEq(vote.weight(), weight, "weight");
        assertEq(vote.swapFee(), swapFee, "swapFee");
        assertEq(vote.timestamp(), timestamp_, "timestamp");
    }
}
