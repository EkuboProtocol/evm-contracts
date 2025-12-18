// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.31;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {MEVCapture, mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {Incentives} from "../src/Incentives.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {IncentivesDataFetcher} from "../src/lens/IncentivesDataFetcher.sol";
import {QuoteDataFetcher} from "../src/lens/QuoteDataFetcher.sol";
import {TWAMMDataFetcher} from "../src/lens/TWAMMDataFetcher.sol";

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

/// @title DeployAll
/// @notice Deploys the Ekubo protocol contracts
contract DeployAll is Script {
    Core public core;
    Oracle public oracle;
    TWAMM public twamm;
    MEVCapture public mevCapture;
    Incentives public incentives;
    TokenWrapperFactory public tokenWrapperFactory;

    function run() public {
        bytes32 baseSalt = vm.envBytes32("SALT");

        vm.startBroadcast();

        console2.log("Deploying Core...");
        core = new Core{salt: baseSalt}();
        console2.log("Core deployed at", address(core));

        console2.log("Deploying MEVCapture extension...");
        bytes32 mevCaptureInitCodeHash = keccak256(abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)));
        bytes32 mevCaptureSalt = findExtensionSalt(baseSalt, mevCaptureInitCodeHash, mevCaptureCallPoints());
        mevCapture = new MEVCapture{salt: mevCaptureSalt}(core);
        console2.log("MEVCapture deployed at", address(mevCapture));

        console2.log("Deploying Oracle extension...");
        bytes32 oracleInitCodeHash = keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core)));
        bytes32 oracleSalt = findExtensionSalt(baseSalt, oracleInitCodeHash, oracleCallPoints());
        oracle = new Oracle{salt: oracleSalt}(core);
        console2.log("Oracle deployed at", address(oracle));

        console2.log("Deploying TWAMM extension...");
        bytes32 twammInitCodeHash = keccak256(abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)));
        bytes32 twammSalt = findExtensionSalt(baseSalt, twammInitCodeHash, twammCallPoints());
        twamm = new TWAMM{salt: twammSalt}(core);
        console2.log("TWAMM deployed at", address(twamm));

        console2.log("Deploying Incentives...");
        incentives = new Incentives{salt: baseSalt}();
        console2.log("Incentives deployed at", address(incentives));

        console2.log("Deploying TokenWrapperFactory...");
        tokenWrapperFactory = new TokenWrapperFactory{salt: baseSalt}(core);
        console2.log("TokenWrapperFactory deployed at", address(tokenWrapperFactory));

        console2.log("Deployed new CoreDataFetcher", address(new CoreDataFetcher{salt: baseSalt}(core)));
        console2.log("Deployed new QuoteDataFetcher", address(new QuoteDataFetcher{salt: baseSalt}(core)));
        console2.log("Deployed new TWAMMDataFetcher", address(new TWAMMDataFetcher{salt: baseSalt}(core, twamm)));
        console2.log(
            "Deployed new IncentivesDataFetcher", address(new IncentivesDataFetcher{salt: baseSalt}(incentives))
        );

        vm.stopBroadcast();
    }
}
