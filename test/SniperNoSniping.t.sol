// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING, NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
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
        snos = new SniperNoSniping(
            router, positions, orders, 4096, 3600, 1_000_000e18, uint64((uint256(1) << 64) / 100), 19802
        );
    }

    function test_launch_gas() public {
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }

    function test_launch() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        assertEq(token.symbol(), "ABC");
        assertEq(token.name(), "ABC Token");
    }

    function test_graduate_gas() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: 10000}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            10000,
            type(uint112).max
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);
        vm.snapshotGasLastCall("SniperNoSniping#graduate");
    }

    function test_collect_gas() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: 10000}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            10000,
            type(uint112).max
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);

        vm.warp(4096 + 4096 + 4096);

        snos.collect(token, address(0x1234));
        vm.snapshotGasLastCall("SniperNoSniping#collect");
    }
}
