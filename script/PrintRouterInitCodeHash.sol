// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Router} from "../src/Router.sol";

contract PrintRouterInitCodeHash is Script {
    function run() public pure {
        bytes memory initCode = abi.encodePacked(
            type(Router).creationCode,
            abi.encode(
                // Core =
                address(0x00000000000014aA86C5d3c41765bb24e11bd701),
                // MEVCapture =
                address(0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be),
                // Ve33 =
                address(0)
            )
        );

        console.log("Initcode");
        console.logBytes(initCode);

        console.log("Router init code hash: ");
        console.logBytes32(keccak256(initCode));
    }
}
