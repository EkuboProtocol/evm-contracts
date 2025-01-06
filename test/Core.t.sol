// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";

contract CounterTest is Test {
    Core public core;

    function setUp() public {
        core = new Core(address(0x0));
    }

    function test_deployed() public {}
}
