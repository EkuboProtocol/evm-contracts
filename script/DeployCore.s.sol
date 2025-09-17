// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function getCreate2Address(bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash)))));
}

function findExtensionSalt(bytes32 startingSalt, bytes32 initCodeHash, CallPoints memory callPoints)
    pure
    returns (bytes32 salt)
{
    salt = startingSalt;
    uint8 startingByte = callPoints.toUint8();

    unchecked {
        while (true) {
            uint8 predictedStartingByte = uint8(uint160(getCreate2Address(salt, initCodeHash)) >> 152);

            if (predictedStartingByte == startingByte) {
                break;
            }

            salt = bytes32(uint256(salt) + 1);
        }
    }
}

/// @dev This script is meant to be idempotent so it can re-run on many chains to deploy the shared infra
contract DeployCore is Script {
    error CoreAddressDifferentThanExpected(address actual, address expected);
    error OracleAddressDifferentThanExpected(address actual, address expected);

    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        address expected = vm.envAddress("EXPECTED_ADDRESS");

        vm.startBroadcast();

        Core core;
        if (address(expected).code.length != 0) {
            core = new Core{salt: salt}();
            if (address(core) != expected) {
                revert CoreAddressDifferentThanExpected(address(core), expected);
            }
            assert(address(core) == expected);
        } else {
            core = Core(payable(expected));
        }

        bytes32 oracleInitCodeHash = keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core)));
        bytes32 oracleSalt = findExtensionSalt(salt, oracleInitCodeHash, oracleCallPoints());
        address expectedOracleAddress = getCreate2Address(oracleSalt, oracleInitCodeHash);

        if (address(expectedOracleAddress).code.length != 0) {
            Oracle oracle = new Oracle{salt: oracleSalt}(core);
            if (address(oracle) != expectedOracleAddress) {
                revert OracleAddressDifferentThanExpected(address(oracle), expectedOracleAddress);
            }
        }

        vm.stopBroadcast();
    }
}
