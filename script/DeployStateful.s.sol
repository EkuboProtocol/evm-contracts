// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {Orders} from "../src/Orders.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";

function getCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function findExtensionSalt(bytes32 startingSalt, bytes32 initCodeHash, CallPoints memory callPoints)
    pure
    returns (bytes32 salt)
{
    salt = startingSalt;
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

contract DeployStatefulScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function run() public {
        address owner = vm.getWallets()[0];

        string memory positionsBaseUrl;
        string memory ordersBaseUrl;
        if (block.chainid == 1) {
            positionsBaseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/positions/nft/"));
            ordersBaseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/orders/nft/"));
        } else if (block.chainid == 11155111) {
            positionsBaseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/positions/nft/"));
            ordersBaseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/orders/nft/"));
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        Core core = new Core{salt: salt}(owner);

        // we deploy with empty url so it has the same address across chains
        BaseURLTokenURIGenerator positionsTokenURIGenerator = new BaseURLTokenURIGenerator{
            salt: keccak256(abi.encodePacked(type(Positions).creationCode, salt))
        }(owner, "");
        positionsTokenURIGenerator.setBaseURL(positionsBaseUrl);

        new Positions{salt: salt}(core, positionsTokenURIGenerator);
        new Oracle{
            salt: findExtensionSalt(
                salt, keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core))), oracleCallPoints()
            )
        }(core);
        TWAMM twamm = new TWAMM{
            salt: findExtensionSalt(
                salt, keccak256(abi.encodePacked(type(TWAMM).creationCode, abi.encode(core))), twammCallPoints()
            )
        }(core);

        BaseURLTokenURIGenerator ordersTokenURIGenerator =
            new BaseURLTokenURIGenerator{salt: keccak256(abi.encodePacked(type(Orders).creationCode, salt))}(owner, "");
        ordersTokenURIGenerator.setBaseURL(ordersBaseUrl);

        new Orders{salt: salt}(core, twamm, ordersTokenURIGenerator);

        vm.stopBroadcast();
    }
}
