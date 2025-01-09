// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";

contract CounterScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    address public owner = vm.envAddress("CORE_OWNER");
    Core public core;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        core = new Core(owner);

        vm.stopBroadcast();
    }
}
