// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {PendingFloor, createPendingFloor} from "../../src/types/pendingFloor.sol";

contract PendingFloorTest is Test {
    function test_packingRoundtrip(uint96 rate, uint48 start) public pure {
        PendingFloor floor = createPendingFloor(rate, start);
        assertEq(floor.floorRate(), rate);
        assertEq(floor.floorStart(), start);
    }

    function test_zeroIsEmpty() public pure {
        PendingFloor floor = createPendingFloor(0, 0);
        assertEq(PendingFloor.unwrap(floor), bytes32(0));
    }

    function test_fieldsDoNotOverlap() public pure {
        PendingFloor floor = createPendingFloor(type(uint96).max, type(uint48).max);
        assertEq(floor.floorRate(), type(uint96).max);
        assertEq(floor.floorStart(), type(uint48).max);
    }
}
