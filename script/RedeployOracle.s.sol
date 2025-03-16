// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {findExtensionSalt} from "./DeployStateful.s.sol";

contract RedeployOracleScript is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));

        vm.startBroadcast();

        Oracle oracle = new Oracle{
            salt: findExtensionSalt(
                salt, keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core))), oracleCallPoints()
            )
        }(core);

        new PriceFetcher{salt: salt}(oracle);

        vm.stopBroadcast();
    }
}
