// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../src/AuctionPositions.sol";
import {AuctionPeriphery} from "../src/AuctionPeriphery.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @notice Deterministic deployment using the repository's standard CREATE2 deployer and prefix mining.
contract DeployContinuousAuction is Script {
    function run() public returns (ContinuousAuction auction, AuctionPositions positions, AuctionPeriphery periphery) {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        address token = vm.envAddress("BID_TOKEN");
        address owner = vm.envAddress("OWNER_ADDRESS");
        bytes32 salt = vm.envBytes32("SALT");
        address expectedAuction = vm.envOr("AUCTION_ADDRESS", address(0));
        address expectedPositions = vm.envOr("AUCTION_POSITIONS_ADDRESS", address(0));
        address expectedPeriphery = vm.envOr("AUCTION_PERIPHERY_ADDRESS", address(0));
        vm.startBroadcast();
        (auction, positions, periphery) =
            _deploy(core, token, owner, salt, expectedAuction, expectedPositions, expectedPeriphery);
        vm.stopBroadcast();
    }

    function _deploy(
        ICore core,
        address token,
        address owner,
        bytes32 salt,
        address expectedAuction,
        address expectedPositions,
        address expectedPeriphery
    ) internal returns (ContinuousAuction auction, AuctionPositions positions, AuctionPeriphery periphery) {
        require(address(core).code.length != 0, "CORE_ADDRESS has no code");
        require(token == address(0) || token.code.length != 0, "BID_TOKEN has no code");
        require(owner != address(0), "OWNER_ADDRESS is zero");
        (address extension,) = deployExtension(
            abi.encodePacked(type(ContinuousAuction).creationCode, abi.encode(core, token)),
            salt,
            continuousAuctionCallPoints(),
            expectedAuction,
            "ContinuousAuction"
        );
        auction = ContinuousAuction(extension);
        (address manager,) = deployIfNeeded(
            abi.encodePacked(type(AuctionPositions).creationCode, abi.encode(core, auction, owner)),
            salt,
            expectedPositions,
            "AuctionPositions"
        );
        positions = AuctionPositions(payable(manager));
        (address settler,) = deployIfNeeded(
            abi.encodePacked(type(AuctionPeriphery).creationCode, abi.encode(core, auction)),
            salt,
            expectedPeriphery,
            "AuctionPeriphery"
        );
        periphery = AuctionPeriphery(payable(settler));
    }
}
