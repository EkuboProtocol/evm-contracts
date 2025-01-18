// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {TestToken} from "../test/TestToken.sol";

contract DeployTestTokens is Script {
    address public owner = vm.envAddress("OWNER");

    function run() public {
        vm.startBroadcast();
        new TestToken{salt: bytes32(0x0000000000000000000000000000000000000000000000000000000000000001)}(owner);
        new TestToken{salt: bytes32(0x0000000000000000000000000000000000000000000000000000000000000002)}(owner);
        vm.stopBroadcast();
    }
}
