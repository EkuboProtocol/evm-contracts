// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";

/// @title DeployMEVCaptureRouter
contract DeployMEVCaptureRouter is Script {
    function run() public {
        vm.startBroadcast();

        console2.log(
            "Deployed MEVCaptureRouter",
            address(
                new MEVCaptureRouter{salt: vm.envBytes32("SALT")}(
                    ICore(payable(0x00000000000014aA86C5d3c41765bb24e11bd701)),
                    address(0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be)
                )
            )
        );

        vm.stopBroadcast();
    }
}
