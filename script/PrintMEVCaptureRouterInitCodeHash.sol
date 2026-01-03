// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {console} from "forge-std/console.sol";

contract PrintMEVCaptureRouterInitCodeHash is Script {
    function run() public pure {
        console.log("MEVCaptureRouter init code hash: ");
        console.logBytes32(
            keccak256(
                abi.encodePacked(
                    type(MEVCaptureRouter).creationCode,
                    abi.encode(
                        // Core =
                        address(0x00000000000014aA86C5d3c41765bb24e11bd701),
                        // MEVCapture =
                        address(0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be)
                    )
                )
            )
        );
    }
}
