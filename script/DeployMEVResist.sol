// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {MEVResist, mevResistCallPoints} from "../src/extensions/MEVResist.sol";
import {findExtensionSalt} from "./DeployStateful.s.sol";

contract DeployMEVResist is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));

        vm.startBroadcast();

        new MEVResist{
            salt: findExtensionSalt(
                salt, keccak256(abi.encodePacked(type(MEVResist).creationCode, abi.encode(core))), mevResistCallPoints()
            )
        }(core);

        vm.stopBroadcast();
    }
}
