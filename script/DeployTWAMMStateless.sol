// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {TWAMM} from "../src/extensions/TWAMM.sol";
import {TWAMMDataFetcher} from "../src/lens/TWAMMDataFetcher.sol";

contract DeployTWAMMStatelessScript is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        Core core = Core(payable(vm.envAddress("CORE_ADDRESS")));
        TWAMM twamm = TWAMM(payable(vm.envAddress("TWAMM_ADDRESS")));

        vm.startBroadcast();

        new TWAMMDataFetcher{salt: salt}(core, twamm);

        vm.stopBroadcast();
    }
}
