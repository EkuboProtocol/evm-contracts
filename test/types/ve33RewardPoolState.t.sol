// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ve33RewardPoolState, createVe33RewardPoolState} from "../../src/types/ve33RewardPoolState.sol";

contract Ve33RewardPoolStateTest is Test {
    function test_conversionToAndFrom(Ve33RewardPoolState state) public pure {
        assertEq(
            Ve33RewardPoolState.unwrap(createVe33RewardPoolState(state.lastAccumulated(), state.rewardRate())),
            Ve33RewardPoolState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(uint32 lastAccumulated, uint224 rewardRate) public pure {
        Ve33RewardPoolState state = createVe33RewardPoolState(lastAccumulated, rewardRate);
        (uint32 parsedLastAccumulated, uint224 parsedRewardRate) = state.parseRewardPoolState();
        assertEq(state.lastAccumulated(), lastAccumulated);
        assertEq(state.rewardRate(), rewardRate);
        assertEq(parsedLastAccumulated, lastAccumulated);
        assertEq(parsedRewardRate, rewardRate);
    }

    function test_conversionFromAndToDirtyBits(bytes32 lastAccumulatedDirty, bytes32 rewardRateDirty) public pure {
        uint32 lastAccumulated;
        uint224 rewardRate;

        assembly ("memory-safe") {
            lastAccumulated := lastAccumulatedDirty
            rewardRate := rewardRateDirty
        }

        Ve33RewardPoolState state = createVe33RewardPoolState(lastAccumulated, rewardRate);
        assertEq(state.lastAccumulated(), lastAccumulated);
        assertEq(state.rewardRate(), rewardRate);
    }

    function test_realLastAccumulatedSameWindow() public {
        vm.warp((uint256(1) << 32) + 100);
        assertEq(createVe33RewardPoolState(90, 0).realLastAccumulated(), (uint256(1) << 32) + 90);
    }

    function test_realLastAccumulatedPreviousWindow() public {
        vm.warp((uint256(1) << 32) + 100);
        assertEq(createVe33RewardPoolState(110, 0).realLastAccumulated(), 110);
    }
}
