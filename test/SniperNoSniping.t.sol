// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {createPositionId} from "../src/types/positionId.sol";
import {Delta, RouteNode} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, MAX_TICK_SPACING} from "../src/math/constants.sol";
import {MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {OrderKey} from "../src/types/orderKey.sol";
import {getNextLaunchTime, SniperNoSniping, sniperNoSnipingCallPoints} from "../src/SniperNoSniping.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {computeFee} from "../src/math/fee.sol";
import {isTimeValid} from "../src/math/time.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";

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
        uint256 orderDuration = 16 ** bound(orderDurationMagnitude, 1, 6);
        uint256 minLeadTime = orderDuration / 2;

        time = bound(time, 0, type(uint256).max - type(uint32).max);

        vm.warp(time);

        (uint256 startTime, uint256 endTime) = getNextLaunchTime(orderDuration, minLeadTime);

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
        snos.launch({creator: address(this), salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }
}
