// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {Positions, ITokenURIGenerator} from "../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../src/base/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey} from "../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";
import {LibString} from "solady/utils/LibString.sol";

contract PositionsTest is Test {
    ITokenURIGenerator public tokenURIGenerator;
    Core public core;
    Positions public positions;

    function setUp() public {
        core = new Core(address(0xdeadbeef));
        tokenURIGenerator = new BaseURLTokenURIGenerator("ekubo://positions/");
        positions = new Positions(core, tokenURIGenerator);
    }

    function test_metadata() public view {
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/1");
    }
}
