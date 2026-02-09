// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Auctions} from "../src/Auctions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";

/// @title DeployAuctions
/// @notice Deploys the Auctions manager with an explicit owner for governance-controlled operations
contract DeployAuctions is Script {
    Auctions public auctions;

    function run() public {
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        bytes32 salt = vm.envOr("SALT", bytes32(0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        ITWAMM twamm = ITWAMM(vm.envOr("TWAMM_ADDRESS", address(0xd4F1060cB9c1A13e1d2d20379b8aa2cF7541eD9b)));
        address boostedFees = vm.envOr("BOOSTED_FEES_ADDRESS", address(0xd4B54d0ca6979Da05F25895E6e269E678ba00f9e));
        string memory auctionsBaseUrl = _envStringOr("AUCTIONS_BASE_URL", "https://prod-api.ekubo.org/auctions/");

        vm.startBroadcast();

        console2.log("Deploying Auctions...");
        auctions = new Auctions{salt: salt}(owner, core, twamm, boostedFees);
        console2.log("Auctions deployed at", address(auctions));

        auctions.setMetadata({newName: "Ekubo Auctions", newSymbol: "ekuAuc", newBaseUrl: auctionsBaseUrl});
        console2.log("Set auctions metadata");

        vm.stopBroadcast();
    }

    function _envStringOr(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = defaultValue;
        }
    }
}
