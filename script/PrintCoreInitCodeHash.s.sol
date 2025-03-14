// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {console} from "forge-std/console.sol";

contract PrintCoreInitCodeHashScript is Script {
    function run() public {
        address owner = vm.getWallets()[0];

        console.log("Owner: ", owner);

        console.log("Core init code hash");
        console.logBytes32(keccak256(abi.encodePacked(type(Core).creationCode, abi.encode(owner))));
    }
}
