// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";

contract CounterTest is Test {
    Core public core;

    function setUp() public {
        core = new Core();
    }

    function test_deployed() public {

    }
//
//    function testFuzz_SetNumber(uint256 x) public {
//        core.setNumber(x);
//        assertEq(core.number(), x);
//    }
}
