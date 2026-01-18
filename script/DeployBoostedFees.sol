// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {BoostedFees, boostedFeesCallPoints} from "../src/extensions/BoostedFees.sol";
import {findExtensionSalt} from "./DeployAll.s.sol";
import {BoostedFeesDataFetcher} from "../src/lens/BoostedFeesDataFetcher.sol";
import {ManualPoolBooster} from "../src/ManualPoolBooster.sol";

/// @title DeployBoostedFees
/// @notice Deploys the BoostedFees contract
contract DeployBoostedFees is Script {
    Core public core = Core(payable(0x00000000000014aA86C5d3c41765bb24e11bd701));

    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        vm.startBroadcast();

        console2.log("Deploying BoostedFees(concentrated) extension...");
        bytes32 boostedFeesConcentratedInitCodeHash =
            keccak256(abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)));
        bytes32 boostedFeesConcentratedSalt =
            findExtensionSalt(DEPLOYMENT_SALT, boostedFeesConcentratedInitCodeHash, boostedFeesCallPoints(true));
        BoostedFees boostedFeesConcentrated = new BoostedFees{salt: boostedFeesConcentratedSalt}(core, true);
        console2.log("BoostedFees(concentrated) deployed at", address(boostedFeesConcentrated));

        console2.log("Deploying BoostedFees(stableswap) extension...");
        bytes32 boostedFeesStableswapInitCodeHash =
            keccak256(abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, false)));
        bytes32 boostedFeesStableswapSalt =
            findExtensionSalt(DEPLOYMENT_SALT, boostedFeesStableswapInitCodeHash, boostedFeesCallPoints(false));
        BoostedFees boostedFeesStableswap = new BoostedFees{salt: boostedFeesStableswapSalt}(core, false);
        console2.log("BoostedFees(concentrated) deployed at", address(boostedFeesStableswap));

        console2.log("Deployed ManualPoolBooster", address(new ManualPoolBooster{salt: DEPLOYMENT_SALT}(core)));
        console2.log(
            "Deployed BoostedFeesDataFetcher", address(new BoostedFeesDataFetcher{salt: DEPLOYMENT_SALT}(core))
        );

        vm.stopBroadcast();
    }
}
