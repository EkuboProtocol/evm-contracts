// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {MEVCapture, _mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {findExtensionSalt} from "./DeployCore.s.sol";

contract DeployMEVCapture is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));

        vm.startBroadcast();

        address mevCapture = address(
            new MEVCapture{
                salt: findExtensionSalt(
                    salt,
                    keccak256(abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core))),
                    _mevCaptureCallPoints()
                )
            }(core)
        );

        new MEVCaptureRouter{salt: salt}(core, mevCapture);

        vm.stopBroadcast();
    }
}
