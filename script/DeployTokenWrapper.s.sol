// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {TokenWrapperPeriphery} from "../src/TokenWrapperPeriphery.sol";
import {ICore} from "../src/interfaces/ICore.sol";

contract DeployTokenWrapperScript is Script {
    function run() public {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new TokenWrapperFactory{salt: salt}(core);
        new TokenWrapperPeriphery{salt: salt}(core);

        vm.stopBroadcast();
    }
}
