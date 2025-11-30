// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity >=0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {MEVCapture, mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {Orders} from "../src/Orders.sol";
import {Incentives} from "../src/Incentives.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {findExtensionSalt} from "./DeployCore.s.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";

/// @title DeployAll
/// @notice Deploys the core Ekubo protocol contracts needed for local testing.
/// @dev This script intentionally skips deterministic salt inputs and simply finds extension salts that match the expected call points.
contract DeployAll is Script {
    Core public core;
    Positions public positions;
    Oracle public oracle;
    TWAMM public twamm;
    MEVCapture public mevCapture;
    Orders public orders;
    Incentives public incentives;
    TokenWrapperFactory public tokenWrapperFactory;

    function run() public {
        address deployer = vm.getWallets()[0];
        bytes32 baseSalt = bytes32(0);

        vm.startBroadcast();

        console2.log("Deploying Core...");
        core = new Core();
        console2.log("Core deployed at", address(core));

        console2.log("Deploying Positions...");
        positions = new Positions(core, deployer, 0, 1);
        console2.log("Positions deployed at", address(positions));

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

        console2.log("Deploying Orders...");
        orders = new Orders(core, ITWAMM(address(twamm)), deployer);
        console2.log("Orders deployed at", address(orders));

        console2.log("Deploying Incentives...");
        incentives = new Incentives();
        console2.log("Incentives deployed at", address(incentives));

        console2.log("Deploying TokenWrapperFactory...");
        tokenWrapperFactory = new TokenWrapperFactory(core);
        console2.log("TokenWrapperFactory deployed at", address(tokenWrapperFactory));

        vm.stopBroadcast();
    }
}
