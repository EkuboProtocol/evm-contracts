// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function getCreate2Address(bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash)))));
}

contract DeployCore is Script {
    error CoreAddressDifferentThanExpected(address actual, address expected);

    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        address expected = vm.envAddress("EXPECTED_ADDRESS");
        address actual = getCreate2Address(salt, keccak256(type(Core).creationCode));

        if (expected != actual) {
            revert CoreAddressDifferentThanExpected(actual, expected);
        }

        if (address(expected).code.length != 0) {
            return;
        }

        vm.startBroadcast();
        Core core = new Core{salt: salt}();
        vm.stopBroadcast();
    }
}
