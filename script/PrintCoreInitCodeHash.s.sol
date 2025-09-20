// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {console} from "forge-std/console.sol";

contract PrintCoreInitCodeHashScript is Script {
    function run() public pure {
        console.log("Core init code hash: ");
        console.logBytes32(keccak256(type(Core).creationCode));
    }
}
