// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {CoreProxyDeployer} from "../src/CoreProxyDeployer.sol";

contract CounterScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    address public owner = vm.envAddress("OWNER");

    Core public core;
    CoreProxyDeployer public deployer;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        core = new Core();
        deployer = new CoreProxyDeployer(address(core), owner);

        vm.stopBroadcast();
    }
}
