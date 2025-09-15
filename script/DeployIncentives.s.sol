// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Incentives} from "../src/Incentives.sol";

contract DeployIncentives is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new Incentives{salt: salt}();

        vm.stopBroadcast();
    }
}
