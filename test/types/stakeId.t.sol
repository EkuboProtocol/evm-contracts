// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StakeId, createStakeId} from "../../src/types/stakeId.sol";

contract StakeIdTest is Test {
    function test_conversionToAndFrom(StakeId id) public pure {
        assertEq(StakeId.unwrap(createStakeId(id.salt(), id.endTime())), StakeId.unwrap(id));
    }

    function test_conversionFromAndTo(bytes24 salt, uint64 endTime) public pure {
        StakeId id = createStakeId(salt, endTime);
        assertEq(id.salt(), salt);
        assertEq(id.endTime(), endTime);
    }

    function test_conversionFromAndToDirtyBits(bytes32 saltDirty, bytes32 endTimeDirty) public pure {
        bytes24 salt;
        uint64 endTime;

        assembly ("memory-safe") {
            salt := saltDirty
            endTime := endTimeDirty
        }

        StakeId id = createStakeId(salt, endTime);
        assertEq(id.salt(), salt);
        assertEq(id.endTime(), endTime);
    }
}
