// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {CallPoints} from "../src/types/callPoints.sol";

import {NATIVE_TOKEN_ADDRESS} from "../src/interfaces/IFlashAccountant.sol";

function getCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function findExtensionSalt(bytes32 initCodeHash, CallPoints memory callPoints) pure returns (bytes32 salt) {
    uint8 startingByte = callPoints.toUint8();

    unchecked {
        while (true) {
            uint8 predictedStartingByte =
                uint8(uint160(getCreate2Address(DETERMINISTIC_DEPLOYER, salt, initCodeHash)) >> 152);

            if (predictedStartingByte == startingByte) {
                break;
            }

            salt = bytes32(uint256(salt) + 1);
        }
    }
}

contract DeployScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function run() public {
        address owner = vm.getWallets()[0];

        string memory baseUrl;
        address oracleToken;
        if (block.chainid == 1) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/positions/nft/"));
        } else if (block.chainid == 11155111) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/positions/nft/"));
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        vm.startBroadcast();

        Core core = new Core{salt: 0x0}(owner);
        // we deploy with empty url so it has the same address
        BaseURLTokenURIGenerator tokenURIGenerator = new BaseURLTokenURIGenerator{salt: 0x0}(owner, "");
        tokenURIGenerator.setBaseURL(baseUrl);
        new Positions{salt: 0x0}(core, tokenURIGenerator);
        new Oracle{
            salt: findExtensionSalt(
                keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core, NATIVE_TOKEN_ADDRESS))),
                oracleCallPoints()
            )
        }(core, NATIVE_TOKEN_ADDRESS);

        vm.stopBroadcast();
    }
}
