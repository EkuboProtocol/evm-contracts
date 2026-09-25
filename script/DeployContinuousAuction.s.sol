// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../src/AuctionPositions.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @notice Deterministic deployment using the repository's standard CREATE2 deployer and prefix mining.
contract DeployContinuousAuction is Script {
    function run() public returns (ContinuousAuction auction, AuctionPositions positions) {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        address token = vm.envAddress("BID_TOKEN");
        address owner = vm.envAddress("OWNER_ADDRESS");
        uint32 noticePeriod = uint32(vm.envUint("NOTICE_PERIOD"));
        uint16 minIncrementBps = uint16(vm.envUint("MIN_INCREMENT_BPS"));
        bytes32 salt = vm.envBytes32("SALT");
        address expectedAuction = vm.envOr("AUCTION_ADDRESS", address(0));
        address expectedPositions = vm.envOr("AUCTION_POSITIONS_ADDRESS", address(0));
        vm.startBroadcast();
        (auction, positions) =
            _deploy(core, token, owner, noticePeriod, minIncrementBps, salt, expectedAuction, expectedPositions);
        vm.stopBroadcast();
    }

    function _deploy(
        ICore core,
        address token,
        address owner,
        uint32 noticePeriod,
        uint16 minIncrementBps,
        bytes32 salt,
        address expectedAuction,
        address expectedPositions
    ) internal returns (ContinuousAuction auction, AuctionPositions positions) {
        require(address(core).code.length != 0, "CORE_ADDRESS has no code");
        require(token == address(0) || token.code.length != 0, "BID_TOKEN has no code");
        require(owner != address(0), "OWNER_ADDRESS is zero");
        require(noticePeriod <= 30 days, "NOTICE_PERIOD too long");
        require(minIncrementBps <= 10000, "MIN_INCREMENT_BPS above 100%");
        (address extension,) = deployExtension(
            abi.encodePacked(
                type(ContinuousAuction).creationCode, abi.encode(core, token, noticePeriod, minIncrementBps)
            ),
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
    }
}
