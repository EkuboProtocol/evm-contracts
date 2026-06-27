// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployVe33
/// @notice Deploys the Ve33 extension, VeToken ERC721 wrapper, Ve33Positions, and Ve33Periphery.
contract DeployVe33 is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address positionsOwner = vm.envOr("VE33_POSITIONS_OWNER", msg.sender);
        uint64 rewardProtocolFeeX64 = uint64(vm.envOr("VE33_POSITIONS_REWARD_PROTOCOL_FEE_X64", uint256(0)));
        address expectedVe33 = vm.envOr("VE33_ADDRESS", address(0));
        address expectedVeToken = vm.envOr("VE_TOKEN_ADDRESS", address(0));
        address expectedPositions = vm.envOr("VE33_POSITIONS_ADDRESS", address(0));
        address expectedPeriphery = vm.envOr("VE33_PERIPHERY_ADDRESS", address(0));

        vm.startBroadcast();

        (address ve33Address,) = deployExtension(
            abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stakeToken)),
            salt,
            ve33CallPoints(),
            expectedVe33,
            "Ve33"
        );

        Ve33 ve33 = Ve33(payable(ve33Address));

        deployIfNeeded(
            abi.encodePacked(type(VeToken).creationCode, abi.encode(core, ve33)), salt, expectedVeToken, "VeToken"
        );
        deployIfNeeded(
            abi.encodePacked(
                type(Ve33Positions).creationCode, abi.encode(core, ve33, positionsOwner, rewardProtocolFeeX64)
            ),
            salt,
            expectedPositions,
            "Ve33Positions"
        );
        deployIfNeeded(
            abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
            salt,
            expectedPeriphery,
            "Ve33Periphery"
        );
        vm.stopBroadcast();
    }
}
