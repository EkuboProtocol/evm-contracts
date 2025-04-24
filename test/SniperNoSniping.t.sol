// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {nextValidTime} from "../src/math/time.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../src/libraries/TWAMMLib.sol";
import {FeeAccumulatingExtension} from "./SolvencyInvariantTest.t.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {Orders} from "../src/Orders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {TWAMM, OrderKey} from "../src/extensions/TWAMM.sol";
import {SniperNoSniping, SNOSToken} from "../src/SniperNoSniping.sol";
import {LibString} from "solady/utils/LibString.sol";

contract SniperNoSnipingTest is BaseOrdersTest {
    SniperNoSniping snos;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        snos = new SniperNoSniping(router, positions, orders, 4096, 3600, 1_000_000e18);
    }

    function test_launch_gas() public {
        snos.launch({
            salt: bytes32(0),
            owner: address(this),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }

    function test_launch() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            owner: address(this),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
    }

    function test_graduate_gas() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            owner: address(this),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.warp(4096 + 4096);

        snos.graduate(token);
        vm.snapshotGasLastCall("SniperNoSniping#graduate no proceeds");
    }
}
