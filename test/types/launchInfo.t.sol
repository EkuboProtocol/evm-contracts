// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {LaunchInfo, createLaunchInfo} from "../../src/types/launchInfo.sol";

contract LaunchInfoTest is Test {
    function test_conversionToAndFrom(LaunchInfo launchInfo) public pure {
        assertEq(
            LaunchInfo.unwrap(
                createLaunchInfo({
                    _endTime: launchInfo.endTime(),
                    _creator: launchInfo.creator(),
                    _saleEndTick: launchInfo.saleEndTick()
                })
            ),
            LaunchInfo.unwrap(launchInfo)
        );
    }

    function test_conversionFromAndTo(uint64 endTime, address creator, int32 saleEndTick) public pure {
        LaunchInfo launchInfo = createLaunchInfo({_endTime: endTime, _creator: creator, _saleEndTick: saleEndTick});
        assertEq(launchInfo.endTime(), endTime);
        assertEq(launchInfo.creator(), creator);
        assertEq(launchInfo.saleEndTick(), saleEndTick);
    }

    function test_conversionFromAndToDirtyBits(bytes32 endTimeDirty, bytes32 creatorDirty, bytes32 saleEndTickDirty)
        public
        pure
    {
        uint64 endTime;
        address creator;
        int32 saleEndTick;

        assembly ("memory-safe") {
            endTime := endTimeDirty
            creator := creatorDirty
            saleEndTick := saleEndTickDirty
        }

        LaunchInfo launchInfo = createLaunchInfo({_endTime: endTime, _creator: creator, _saleEndTick: saleEndTick});
        assertEq(launchInfo.endTime(), endTime, "endTime");
        assertEq(launchInfo.creator(), creator, "creator");
        assertEq(launchInfo.saleEndTick(), saleEndTick, "saleEndTick");
    }
}
