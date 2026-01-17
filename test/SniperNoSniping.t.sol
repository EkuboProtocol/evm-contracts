// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {BaseOrdersTest} from "./Orders.t.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {getNextLaunchTime, SniperNoSniping, sniperNoSnipingCallPoints} from "../src/SniperNoSniping.sol";
import {isTimeValid} from "../src/math/time.sol";

contract SniperNoSnipingTest is BaseOrdersTest {
    using CoreLib for *;

    SniperNoSniping snos;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        address deployAddress = address(uint160(sniperNoSnipingCallPoints().toUint8()) << 152);
        uint256 orderDurationMagnitude = 4;
        uint128 tokenTotalSupply = 69_420_000e18;
        uint64 poolFee = uint64((uint256(1) << 64) / 100);
        uint32 tickSpacing = 1000;
        deployCodeTo(
            "SniperNoSniping.sol",
            abi.encode(core, twamm, orderDurationMagnitude, tokenTotalSupply, poolFee, tickSpacing),
            deployAddress
        );
        snos = SniperNoSniping(deployAddress);
    }

    function test_get_next_launch_time_invariants(uint256 orderDurationMagnitude, uint256 time) public {
        uint32 orderDuration = uint32(16) ** uint32(bound(orderDurationMagnitude, 2, 6));
        uint32 minLeadTime = orderDuration / 2;

        time = bound(time, 0, type(uint64).max - type(uint32).max);

        vm.warp(time);

        (uint64 startTime, uint64 endTime) = getNextLaunchTime(orderDuration, minLeadTime);

        assertNotEq(startTime, 0);
        assertNotEq(endTime, 0);
        assertGt(endTime, startTime);

        assertGe(startTime, time + minLeadTime);
        assertLe(startTime, time + minLeadTime + orderDuration);
        assertEq(endTime - startTime, orderDuration, "order duration is exact");
        assertTrue(isTimeValid(time, startTime), "start time is valid");
        assertTrue(isTimeValid(time, endTime), "end time is valid");
    }

    function test_launch_gas() public {
        snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }
}
