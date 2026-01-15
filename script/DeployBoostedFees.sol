// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {BoostedFees, boostedFeesCallPoints} from "../src/extensions/BoostedFees.sol";
import {findExtensionSalt} from "./DeployAll.s.sol";

/// @title DeployBoostedFees
/// @notice Deploys the BoostedFees contract
contract DeployBoostedFees is Script {
    Core public core = Core(payable(0x00000000000014aA86C5d3c41765bb24e11bd701));

    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        vm.startBroadcast();

        console2.log("Deploying BoostedFees extension...");
        bytes32 boostedFeesInitCodeHash = keccak256(abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core)));
        bytes32 boostedFeesSalt = findExtensionSalt(DEPLOYMENT_SALT, boostedFeesInitCodeHash, boostedFeesCallPoints());
        BoostedFees boostedFees = new BoostedFees{salt: boostedFeesSalt}(core);
        console2.log("BoostedFees deployed at", address(boostedFees));

        vm.stopBroadcast();
    }
}
